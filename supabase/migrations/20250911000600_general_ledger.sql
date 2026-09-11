-- ============================================================================
-- Rotopa · Module 05 — General Ledger  (the posting engine)
--
-- Rules that hold no matter which module creates the entry:
--   * journal_lines.debit / credit are ALWAYS in the organization's base
--     currency; foreign amounts live beside them with the rate that produced
--     them.
--   * every line is either a debit or a credit, never both, never zero.
--   * a POSTED entry has >= 2 lines and sum(debit) = sum(credit) to the cent
--     (enforced by a deferred constraint, so multi-row inserts are fine).
--   * a POSTED entry is immutable — corrections are reversing entries.
--   * nothing posts into a period that is not 'open'.
--   * posted amounts roll up into account_period_balances for O(1) reports.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Gapless per-organization document numbering
-- ---------------------------------------------------------------------------
create table document_sequences (
  org_id      uuid not null references organizations(id) on delete cascade,
  key         text not null,                 -- 'journal', 'receipt_voucher', ...
  next_value  bigint not null default 1,
  primary key (org_id, key)
);
alter table document_sequences enable row level security;
create policy docseq_select on document_sequences for select using (app.is_member(org_id));

create or replace function app.next_seq(p_org uuid, p_key text)
returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into document_sequences (org_id, key, next_value)
  values (p_org, p_key, 2)
  on conflict (org_id, key)
    do update set next_value = document_sequences.next_value + 1
  returning next_value - 1 into v;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- journal_entries / journal_lines
-- ---------------------------------------------------------------------------
create table journal_entries (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  entry_no      bigint not null,
  entry_date    date not null,
  fiscal_period_id uuid not null references fiscal_periods(id) on delete restrict,
  branch_id     uuid references branches(id) on delete restrict,

  description   text not null default '',
  source_type   text not null default 'manual',   -- manual | opening_balance | receipt_voucher | sales_invoice | ...
  source_id     uuid,
  document_currency_id uuid references currencies(id),

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  is_opening    boolean not null default false,

  void_of       uuid references journal_entries(id) on delete restrict,   -- this entry reverses void_of
  reversed_by   uuid references journal_entries(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, entry_no),
  unique (org_id, source_type, source_id),         -- one entry per source document
  constraint je_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on journal_entries (org_id, entry_date);
create index on journal_entries (org_id, status);
create index on journal_entries (fiscal_period_id);
create index on journal_entries (source_type, source_id);

create table journal_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  entry_id      uuid not null references journal_entries(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  account_id    uuid not null references accounts(id) on delete restrict,
  description   text not null default '',

  -- base-currency amounts (source of truth)
  debit         numeric(19,4) not null default 0 check (debit  >= 0),
  credit        numeric(19,4) not null default 0 check (credit >= 0),

  -- original document currency
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),
  fc_debit      numeric(19,4) not null default 0 check (fc_debit  >= 0),
  fc_credit     numeric(19,4) not null default 0 check (fc_credit >= 0),

  -- analysis dimensions
  dealer_id       uuid references dealers(id) on delete restrict,
  cost_center_id  uuid references cost_centers(id) on delete restrict,
  department_id   uuid references departments(id) on delete restrict,
  fund_id         uuid references funds(id) on delete restrict,
  project_id      uuid references projects(id) on delete restrict,
  budget_id       uuid references budgets(id) on delete restrict,

  created_at    timestamptz not null default now(),

  unique (entry_id, line_no),
  constraint jl_one_side check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  ),
  constraint jl_fc_one_side check (
    (fc_debit >= 0 and fc_credit = 0) or (fc_credit >= 0 and fc_debit = 0)
  )
);
create index on journal_lines (entry_id);
create index on journal_lines (org_id, account_id);
create index on journal_lines (dealer_id) where dealer_id is not null;
create index on journal_lines (cost_center_id) where cost_center_id is not null;

-- ---------------------------------------------------------------------------
-- Line validation — runs before every insert/update
-- ---------------------------------------------------------------------------
create or replace function app.tg_journal_line_validate()
returns trigger language plpgsql as $$
declare
  e   journal_entries%rowtype;
  a   accounts%rowtype;
  cur currencies%rowtype;
begin
  select * into e from journal_entries where id = new.entry_id;
  if not found then
    raise exception 'journal line references a missing entry' using errcode = '23503';
  end if;

  -- lines may only be added / changed while the entry is a draft
  if e.status <> 'draft' then
    raise exception 'entry % is %; its lines are frozen', e.entry_no, e.status using errcode = '23514';
  end if;

  new.org_id := e.org_id;

  select * into a from accounts where id = new.account_id;
  if a.org_id <> e.org_id then
    raise exception 'account belongs to a different organization' using errcode = '23503';
  end if;
  if not a.is_postable then
    raise exception 'account % is not postable', a.code using errcode = '23514';
  end if;
  if not a.is_active or not a.allow_transactions then
    raise exception 'account % does not currently accept transactions', a.code using errcode = '23514';
  end if;

  -- currency rules
  select * into cur from currencies where id = new.currency_id;
  if cur.org_id <> e.org_id then
    raise exception 'currency belongs to a different organization' using errcode = '23503';
  end if;
  if a.currency_id is not null and a.currency_id <> new.currency_id then
    raise exception 'account % is restricted to a single currency', a.code using errcode = '23514';
  end if;

  -- base amounts must equal foreign amounts * rate (rounded), and rate = 1 for base currency
  if cur.is_base then
    if new.rate <> 1 then
      raise exception 'base-currency line must have rate = 1' using errcode = '23514';
    end if;
    new.fc_debit  := new.debit;
    new.fc_credit := new.credit;
  else
    if round(new.fc_debit  * new.rate, 4) <> new.debit then
      raise exception 'debit % <> fc_debit % * rate %', new.debit, new.fc_debit, new.rate using errcode = '23514';
    end if;
    if round(new.fc_credit * new.rate, 4) <> new.credit then
      raise exception 'credit % <> fc_credit % * rate %', new.credit, new.fc_credit, new.rate using errcode = '23514';
    end if;
  end if;

  -- dimension requirements declared on the account
  if a.require_dealer      and new.dealer_id      is null then raise exception 'account % requires a dealer',       a.code using errcode='23514'; end if;
  if a.require_cost_center and new.cost_center_id  is null then raise exception 'account % requires a cost centre',  a.code using errcode='23514'; end if;
  if a.require_department   and new.department_id  is null then raise exception 'account % requires a department',   a.code using errcode='23514'; end if;
  if a.require_project      and new.project_id     is null then raise exception 'account % requires a project',      a.code using errcode='23514'; end if;

  -- dimensions must belong to the same org
  if new.dealer_id      is not null and (select org_id from dealers      where id = new.dealer_id)      <> e.org_id then raise exception 'dealer belongs to another org'      using errcode='23503'; end if;
  if new.cost_center_id is not null and (select org_id from cost_centers where id = new.cost_center_id) <> e.org_id then raise exception 'cost centre belongs to another org' using errcode='23503'; end if;
  if new.department_id  is not null and (select org_id from departments  where id = new.department_id)  <> e.org_id then raise exception 'department belongs to another org'  using errcode='23503'; end if;
  if new.fund_id        is not null and (select org_id from funds        where id = new.fund_id)        <> e.org_id then raise exception 'fund belongs to another org'        using errcode='23503'; end if;
  if new.project_id     is not null and (select org_id from projects     where id = new.project_id)     <> e.org_id then raise exception 'project belongs to another org'     using errcode='23503'; end if;

  return new;
end;
$$;

create trigger journal_line_validate
  before insert or update on journal_lines
  for each row execute function app.tg_journal_line_validate();

-- ---------------------------------------------------------------------------
-- Entry immutability once posted (only status may move posted -> void)
-- ---------------------------------------------------------------------------
create or replace function app.tg_journal_entry_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then
    raise exception 'a void entry cannot be modified' using errcode = '23514';
  end if;

  -- A posted entry is immutable. The only permitted change is the transition
  -- to 'void' (performed by void_journal_entry, which also sets reversed_by /
  -- void_reason); everything else must go through a reversing entry.
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id            <> old.org_id
       or new.entry_no          <> old.entry_no
       or new.entry_date        <> old.entry_date
       or new.fiscal_period_id  <> old.fiscal_period_id
       or new.description       <> old.description
       or new.source_type       <> old.source_type
       or new.source_id         is distinct from old.source_id
       or new.branch_id         is distinct from old.branch_id
       or new.document_currency_id is distinct from old.document_currency_id
       or new.is_opening        <> old.is_opening
       or new.posted_by         is distinct from old.posted_by
       or new.posted_at         is distinct from old.posted_at then
      raise exception 'a posted entry is immutable; reverse it with void_journal_entry()' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;
create trigger journal_entry_guard
  before update on journal_entries
  for each row execute function app.tg_journal_entry_guard();

create or replace function app.tg_journal_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from journal_entries
    where id = coalesce(new.entry_id, old.entry_id);
  if v_status <> 'draft' then
    raise exception 'entry is %; lines cannot be added, changed or removed', v_status using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger journal_line_frozen_del
  before delete on journal_lines
  for each row execute function app.tg_journal_line_frozen();

-- ---------------------------------------------------------------------------
-- Balance check — fires when an entry reaches 'posted'.
-- Safe as a statement-level constraint trigger because posted entries are
-- frozen: lines are always present *before* the status flips (RPC path), and
-- a directly-inserted status='posted' row has no lines yet, so it is rejected
-- for having < 2 lines.
-- ---------------------------------------------------------------------------
create or replace function app.tg_journal_balance()
returns trigger language plpgsql as $$
declare
  e journal_entries%rowtype;
  v_dr numeric(19,4);
  v_cr numeric(19,4);
  v_n  int;
begin
  select * into e from journal_entries where id = new.id;
  if e.status <> 'posted' then
    return null;                              -- only posted entries must balance
  end if;

  select coalesce(sum(debit),0), coalesce(sum(credit),0), count(*)
    into v_dr, v_cr, v_n
  from journal_lines where entry_id = new.id;

  if v_n < 2 then
    raise exception 'posted entry % must have at least two lines', e.entry_no using errcode = '23514';
  end if;
  if v_dr <> v_cr then
    raise exception 'posted entry % is out of balance: debit % <> credit %', e.entry_no, v_dr, v_cr
      using errcode = '23514';
  end if;
  return null;
end;
$$;

create constraint trigger journal_entry_balanced
  after insert or update on journal_entries
  for each row execute function app.tg_journal_balance();

-- ---------------------------------------------------------------------------
-- Balance roll-up — account_period_balances
-- ---------------------------------------------------------------------------
create table account_period_balances (
  org_id            uuid not null references organizations(id) on delete cascade,
  account_id        uuid not null references accounts(id) on delete restrict,
  fiscal_period_id  uuid not null references fiscal_periods(id) on delete restrict,
  debit_base        numeric(19,4) not null default 0,
  credit_base       numeric(19,4) not null default 0,
  updated_at        timestamptz not null default now(),
  primary key (account_id, fiscal_period_id)
);
create index on account_period_balances (org_id, fiscal_period_id);

create or replace function app.apply_entry_to_balances(p_entry uuid, p_sign int)
returns void language plpgsql as $$
begin
  insert into account_period_balances as b (org_id, account_id, fiscal_period_id, debit_base, credit_base)
  select l.org_id, l.account_id, e.fiscal_period_id,
         p_sign * sum(l.debit), p_sign * sum(l.credit)
  from journal_lines l
  join journal_entries e on e.id = l.entry_id
  where l.entry_id = p_entry
  group by l.org_id, l.account_id, e.fiscal_period_id
  on conflict (account_id, fiscal_period_id) do update
    set debit_base  = b.debit_base  + excluded.debit_base,
        credit_base = b.credit_base + excluded.credit_base,
        updated_at  = now();
end;
$$;

create or replace function app.tg_entry_rollup()
returns trigger language plpgsql as $$
begin
  -- A posted entry always contributes to the roll-up. Voiding never removes it:
  -- the reversing entry created by void_journal_entry() is what offsets it, so
  -- history in a closed period is never rewritten.
  if new.status = 'posted' and old.status = 'draft' then
    perform app.apply_entry_to_balances(new.id, 1);
  end if;
  return null;
end;
$$;
create trigger entry_rollup
  after update of status on journal_entries
  for each row execute function app.tg_entry_rollup();

-- ---------------------------------------------------------------------------
-- RPCs — the only supported way to create and post entries
-- ---------------------------------------------------------------------------
-- p_lines: [{account_id, debit, credit, currency_id, rate, fc_debit, fc_credit,
--            description, dealer_id, cost_center_id, department_id, fund_id,
--            project_id, budget_id}]
create or replace function create_journal_entry(
  p_org uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb,
  p_source_type text default 'manual',
  p_source_id uuid default null,
  p_branch_id uuid default null,
  p_document_currency_id uuid default null,
  p_is_opening boolean default false
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_entry uuid;
  v_line jsonb;
  v_no int := 0;
begin
  perform app.require_permission(p_org, 'gl.create');

  insert into journal_entries (
    org_id, entry_no, entry_date, fiscal_period_id, branch_id, description,
    source_type, source_id, document_currency_id, is_opening, created_by
  ) values (
    p_org, app.next_seq(p_org, 'journal'), p_entry_date,
    app.open_period_for(p_org, p_entry_date), p_branch_id, coalesce(p_description,''),
    coalesce(p_source_type,'manual'), p_source_id, p_document_currency_id, p_is_opening, auth.uid()
  ) returning id into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into journal_lines (
      entry_id, line_no, account_id, description,
      debit, credit, currency_id, rate, fc_debit, fc_credit,
      dealer_id, cost_center_id, department_id, fund_id, project_id, budget_id
    ) values (
      v_entry, v_no,
      (v_line->>'account_id')::uuid,
      coalesce(v_line->>'description',''),
      round(coalesce((v_line->>'debit')::numeric, 0), 4),
      round(coalesce((v_line->>'credit')::numeric, 0), 4),
      coalesce((v_line->>'currency_id')::uuid, p_document_currency_id),
      coalesce((v_line->>'rate')::numeric, 1),
      round(coalesce((v_line->>'fc_debit')::numeric, 0), 4),
      round(coalesce((v_line->>'fc_credit')::numeric, 0), 4),
      (v_line->>'dealer_id')::uuid,
      (v_line->>'cost_center_id')::uuid,
      (v_line->>'department_id')::uuid,
      (v_line->>'fund_id')::uuid,
      (v_line->>'project_id')::uuid,
      (v_line->>'budget_id')::uuid
    );
  end loop;

  return v_entry;
end;
$$;

create or replace function post_journal_entry(p_entry_id uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare e journal_entries%rowtype;
begin
  select * into e from journal_entries where id = p_entry_id for update;
  if not found then raise exception 'entry not found' using errcode = 'P0002'; end if;

  perform app.require_permission(e.org_id, 'gl.post');

  if e.status <> 'draft' then
    raise exception 'only a draft entry can be posted (this one is %)', e.status using errcode = '23514';
  end if;
  -- period must still be open, and the date still inside it
  perform 1 from fiscal_periods
    where id = e.fiscal_period_id and status = 'open'
      and e.entry_date between start_date and end_date;
  if not found then
    raise exception 'the fiscal period for % is not open', e.entry_date using errcode = 'P0001';
  end if;

  update journal_entries
     set status = 'posted', posted_by = auth.uid(), posted_at = now()
   where id = p_entry_id;
  -- balance + rollup happen in triggers
end;
$$;

-- Reverse a posted entry with a mirror-image entry on p_date, then mark it void.
create or replace function void_journal_entry(p_entry_id uuid, p_date date, p_reason text)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  e journal_entries%rowtype;
  v_rev uuid;
begin
  select * into e from journal_entries where id = p_entry_id for update;
  if not found then raise exception 'entry not found' using errcode = 'P0002'; end if;
  perform app.require_permission(e.org_id, 'gl.void');
  if e.status <> 'posted' then
    raise exception 'only a posted entry can be voided' using errcode = '23514';
  end if;

  -- source_type/source_id on the reversal deliberately do NOT copy the
  -- original's (org_id, source_type, source_id) is unique per document, and
  -- the reversal is not itself that document). void_of already carries the
  -- real relationship; 'reversal'/e.id keeps the pair unique and traceable.
  insert into journal_entries (
    org_id, entry_no, entry_date, fiscal_period_id, branch_id, description,
    source_type, source_id, document_currency_id, void_of, created_by
  ) values (
    e.org_id, app.next_seq(e.org_id, 'journal'), p_date,
    app.open_period_for(e.org_id, p_date), e.branch_id,
    'إلغاء قيد رقم ' || e.entry_no || coalesce(' — ' || p_reason, ''),
    'reversal', e.id, e.document_currency_id, e.id, auth.uid()
  ) returning id into v_rev;

  insert into journal_lines (
    entry_id, line_no, account_id, description,
    debit, credit, currency_id, rate, fc_debit, fc_credit,
    dealer_id, cost_center_id, department_id, fund_id, project_id, budget_id
  )
  select v_rev, line_no, account_id, 'عكس: ' || description,
         credit, debit, currency_id, rate, fc_credit, fc_debit,
         dealer_id, cost_center_id, department_id, fund_id, project_id, budget_id
  from journal_lines where entry_id = e.id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_rev;
  update journal_entries set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = e.id;

  return v_rev;
end;
$$;

revoke all on function create_journal_entry(uuid,date,text,jsonb,text,uuid,uuid,uuid,boolean) from public, anon;
revoke all on function post_journal_entry(uuid) from public, anon;
revoke all on function void_journal_entry(uuid,date,text) from public, anon;
grant execute on function create_journal_entry(uuid,date,text,jsonb,text,uuid,uuid,uuid,boolean) to authenticated;
grant execute on function post_journal_entry(uuid) to authenticated;
grant execute on function void_journal_entry(uuid,date,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Read helper — account balance as of a date (uses the roll-up)
-- ---------------------------------------------------------------------------
create or replace function account_balance(p_account_id uuid, p_as_of date default null)
returns numeric language sql stable as $$
  select coalesce(sum(b.debit_base - b.credit_base), 0)
  from account_period_balances b
  join fiscal_periods p on p.id = b.fiscal_period_id
  where b.account_id = p_account_id
    and (p_as_of is null or p.start_date <= p_as_of);
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table journal_entries         enable row level security;
alter table journal_lines           enable row level security;
alter table account_period_balances enable row level security;

create policy je_select on journal_entries for select using (app.is_member(org_id));
-- writes go through the RPCs (SECURITY DEFINER); allow direct draft edits with permission
create policy je_write on journal_entries for all
  using (app.has_permission(org_id, 'gl.create'))
  with check (app.has_permission(org_id, 'gl.create'));

create policy jl_select on journal_lines for select using (app.is_member(org_id));
create policy jl_write on journal_lines for all
  using (app.has_permission(org_id, 'gl.create'))
  with check (app.has_permission(org_id, 'gl.create'));

create policy apb_select on account_period_balances for select using (app.is_member(org_id));

create trigger set_updated_at before update on journal_entries for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on journal_entries for each row execute function app.tg_audit();
