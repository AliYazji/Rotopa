-- ============================================================================
-- Rotopa · Module 06 — Vouchers (سندات القبض والصرف)
--
-- A voucher is one cash/bank leg against one or more "other side" lines:
--   receipt (سند قبض): debit the cash/bank account, credit each line's account
--   payment (سند صرف): credit the cash/bank account, debit each line's account
-- Posting builds the journal entry itself (not via create_journal_entry/
-- post_journal_entry — a voucher-posting permission should not imply direct
-- general-journal rights), through the exact same validated tables.
-- ============================================================================

create table vouchers (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  voucher_type  text not null check (voucher_type in ('receipt','payment')),
  voucher_no    bigint not null,
  voucher_date  date not null,
  description   text not null default '',

  cash_account_id uuid not null references accounts(id) on delete restrict,
  currency_id     uuid not null references currencies(id),
  rate            numeric(19,9) not null default 1 check (rate > 0),
  method          text not null default 'cash' check (method in ('cash','cheque','bank_transfer','mixed')),

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  void_of       uuid references vouchers(id) on delete restrict,
  reversed_by   uuid references vouchers(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, voucher_type, voucher_no),
  constraint voucher_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on vouchers (org_id, voucher_date);
create index on vouchers (org_id, status);

create table voucher_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  voucher_id    uuid not null references vouchers(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  account_id    uuid not null references accounts(id) on delete restrict,
  description   text not null default '',
  amount        numeric(19,4) not null check (amount > 0),   -- in the voucher's currency

  dealer_id       uuid references dealers(id) on delete restrict,
  cost_center_id  uuid references cost_centers(id) on delete restrict,
  department_id   uuid references departments(id) on delete restrict,
  fund_id         uuid references funds(id) on delete restrict,
  budget_id       uuid references budgets(id) on delete restrict,

  unique (voucher_id, line_no)
);
create index on voucher_lines (voucher_id);
create index on voucher_lines (org_id, account_id);

-- ---------------------------------------------------------------------------
-- Validation — same spirit as journal_lines: only while draft, same org,
-- postable/active/transactable account, dimension requirements honoured.
-- ---------------------------------------------------------------------------
create or replace function app.tg_voucher_line_validate()
returns trigger language plpgsql as $$
declare
  v vouchers%rowtype;
  a accounts%rowtype;
begin
  select * into v from vouchers where id = new.voucher_id;
  if not found then
    raise exception 'voucher line references a missing voucher' using errcode = '23503';
  end if;
  if v.status <> 'draft' then
    raise exception 'voucher % is %; its lines are frozen', v.voucher_no, v.status using errcode = '23514';
  end if;
  new.org_id := v.org_id;

  select * into a from accounts where id = new.account_id;
  if a.org_id <> v.org_id then raise exception 'account belongs to a different organization' using errcode = '23503'; end if;
  if not a.is_postable then raise exception 'account % is not postable', a.code using errcode = '23514'; end if;
  if not a.is_active or not a.allow_transactions then
    raise exception 'account % does not currently accept transactions', a.code using errcode = '23514';
  end if;
  if new.account_id = v.cash_account_id then
    raise exception 'a voucher line cannot use the same account as the cash/bank leg' using errcode = '23514';
  end if;
  if a.currency_id is not null and a.currency_id <> v.currency_id then
    raise exception 'account % is restricted to a single currency', a.code using errcode = '23514';
  end if;
  if a.require_dealer      and new.dealer_id      is null then raise exception 'account % requires a dealer',      a.code using errcode='23514'; end if;
  if a.require_cost_center and new.cost_center_id is null then raise exception 'account % requires a cost centre', a.code using errcode='23514'; end if;
  if a.require_department  and new.department_id  is null then raise exception 'account % requires a department',  a.code using errcode='23514'; end if;

  return new;
end;
$$;
create trigger voucher_line_validate
  before insert or update on voucher_lines
  for each row execute function app.tg_voucher_line_validate();

create or replace function app.tg_voucher_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from vouchers where id = old.voucher_id;
  if v_status <> 'draft' then
    raise exception 'voucher is %; lines cannot be removed', v_status using errcode = '23514';
  end if;
  return old;
end;
$$;
create trigger voucher_line_frozen_del
  before delete on voucher_lines
  for each row execute function app.tg_voucher_line_frozen();

create or replace function app.tg_voucher_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then
    raise exception 'a void voucher cannot be modified' using errcode = '23514';
  end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.voucher_no <> old.voucher_no
       or new.voucher_date <> old.voucher_date or new.cash_account_id <> old.cash_account_id
       or new.currency_id <> old.currency_id or new.journal_entry_id is distinct from old.journal_entry_id then
      raise exception 'a posted voucher is immutable; reverse it with void_voucher()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger voucher_guard before update on vouchers for each row execute function app.tg_voucher_guard();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_voucher(
  p_org uuid,
  p_voucher_type text,
  p_voucher_date date,
  p_description text,
  p_cash_account_id uuid,
  p_currency_id uuid,
  p_lines jsonb,               -- [{account_id, amount, description, dealer_id, cost_center_id, department_id, fund_id, budget_id}]
  p_rate numeric default 1,
  p_method text default 'cash'
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_voucher uuid;
  v_line jsonb;
  v_no int := 0;
begin
  perform app.require_permission(p_org, 'vouchers.write');
  if p_voucher_type not in ('receipt','payment') then
    raise exception 'voucher type must be receipt or payment' using errcode = '22023';
  end if;

  insert into vouchers (org_id, voucher_type, voucher_no, voucher_date, description,
                         cash_account_id, currency_id, rate, method, created_by)
  values (p_org, p_voucher_type, app.next_seq(p_org, 'voucher_' || p_voucher_type), p_voucher_date,
          coalesce(p_description,''), p_cash_account_id, p_currency_id, coalesce(p_rate,1),
          coalesce(p_method,'cash'), auth.uid())
  returning id into v_voucher;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into voucher_lines (voucher_id, line_no, account_id, description, amount,
                                dealer_id, cost_center_id, department_id, fund_id, budget_id)
    values (v_voucher, v_no, (v_line->>'account_id')::uuid, coalesce(v_line->>'description',''),
            round(coalesce((v_line->>'amount')::numeric,0), 4),
            (v_line->>'dealer_id')::uuid, (v_line->>'cost_center_id')::uuid,
            (v_line->>'department_id')::uuid, (v_line->>'fund_id')::uuid, (v_line->>'budget_id')::uuid);
  end loop;

  return v_voucher;
end;
$$;

create or replace function post_voucher(p_voucher_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v vouchers%rowtype;
  v_entry uuid;
  v_period uuid;
  v_line record;
  v_no int := 0;
  v_total numeric(19,4) := 0;
begin
  select * into v from vouchers where id = p_voucher_id for update;
  if not found then raise exception 'voucher not found' using errcode = 'P0002'; end if;
  perform app.require_permission(v.org_id, 'vouchers.post');
  if v.status <> 'draft' then
    raise exception 'only a draft voucher can be posted (this one is %)', v.status using errcode = '23514';
  end if;
  if not exists (select 1 from voucher_lines where voucher_id = p_voucher_id) then
    raise exception 'voucher has no lines' using errcode = '23514';
  end if;

  v_period := app.open_period_for(v.org_id, v.voucher_date);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (v.org_id, app.next_seq(v.org_id, 'journal'), v.voucher_date, v_period,
          coalesce(nullif(v.description,''), case v.voucher_type when 'receipt' then 'سند قبض' else 'سند صرف' end),
          case v.voucher_type when 'receipt' then 'receipt_voucher' else 'payment_voucher' end,
          v.id, v.currency_id, v.created_by)
  returning id into v_entry;

  for v_line in select * from voucher_lines where voucher_id = p_voucher_id order by line_no loop
    v_no := v_no + 1;
    v_total := v_total + v_line.amount;
    insert into journal_lines (entry_id, line_no, account_id, description,
                                debit, credit, currency_id, rate, fc_debit, fc_credit,
                                dealer_id, cost_center_id, department_id, fund_id, budget_id)
    values (
      v_entry, v_no, v_line.account_id, v_line.description,
      case when v.voucher_type = 'payment' then round(v_line.amount * v.rate, 4) else 0 end,
      case when v.voucher_type = 'receipt' then round(v_line.amount * v.rate, 4) else 0 end,
      v.currency_id, v.rate,
      case when v.voucher_type = 'payment' then v_line.amount else 0 end,
      case when v.voucher_type = 'receipt' then v_line.amount else 0 end,
      v_line.dealer_id, v_line.cost_center_id, v_line.department_id, v_line.fund_id, v_line.budget_id
    );
  end loop;

  v_no := v_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit,
                              currency_id, rate, fc_debit, fc_credit)
  values (
    v_entry, v_no, v.cash_account_id,
    case v.voucher_type when 'receipt' then 'سند قبض' else 'سند صرف' end,
    case when v.voucher_type = 'receipt' then round(v_total * v.rate, 4) else 0 end,
    case when v.voucher_type = 'payment' then round(v_total * v.rate, 4) else 0 end,
    v.currency_id, v.rate,
    case when v.voucher_type = 'receipt' then v_total else 0 end,
    case when v.voucher_type = 'payment' then v_total else 0 end
  );

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update vouchers set status = 'posted', journal_entry_id = v_entry, posted_by = auth.uid(), posted_at = now()
    where id = p_voucher_id;

  return v_entry;
end;
$$;

create or replace function void_voucher(p_voucher_id uuid, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v vouchers%rowtype;
  v_period uuid;
  v_rev_entry uuid;
  v_rev_voucher uuid;
begin
  select * into v from vouchers where id = p_voucher_id for update;
  if not found then raise exception 'voucher not found' using errcode = 'P0002'; end if;
  perform app.require_permission(v.org_id, 'vouchers.post');
  if v.status <> 'posted' then
    raise exception 'only a posted voucher can be voided' using errcode = '23514';
  end if;

  -- reverse the original entry directly (mirror its lines) rather than
  -- calling void_journal_entry(), so voiding a voucher only ever needs
  -- vouchers.post — not a separate general-ledger permission.
  -- 'reversal'/e.id, not e.source_type/e.source_id — that pair is unique per
  -- source document and the reversal is not itself that document; void_of
  -- already carries the real relationship (see the same note in
  -- void_journal_entry, 20250911000600_general_ledger.sql).
  v_period := app.open_period_for(v.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, void_of, created_by)
  select v.org_id, app.next_seq(v.org_id, 'journal'), p_date, v_period,
         'إلغاء سند رقم ' || v.voucher_no || coalesce(' — ' || p_reason, ''),
         'reversal', e.id, e.document_currency_id, e.id, auth.uid()
  from journal_entries e where e.id = v.journal_entry_id
  returning id into v_rev_entry;

  insert into journal_lines (entry_id, line_no, account_id, description,
                              debit, credit, currency_id, rate, fc_debit, fc_credit,
                              dealer_id, cost_center_id, department_id, fund_id, budget_id)
  select v_rev_entry, line_no, account_id, 'عكس: ' || description,
         credit, debit, currency_id, rate, fc_credit, fc_debit,
         dealer_id, cost_center_id, department_id, fund_id, budget_id
  from journal_lines where entry_id = v.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_rev_entry;
  update journal_entries set status = 'void', reversed_by = v_rev_entry, void_reason = p_reason where id = v.journal_entry_id;

  insert into vouchers (org_id, voucher_type, voucher_no, voucher_date, description,
                         cash_account_id, currency_id, rate, method, journal_entry_id,
                         void_of, status, created_by, posted_by, posted_at)
  values (v.org_id, v.voucher_type, app.next_seq(v.org_id, 'voucher_' || v.voucher_type), p_date,
          'إلغاء سند رقم ' || v.voucher_no || coalesce(' — ' || p_reason, ''),
          v.cash_account_id, v.currency_id, v.rate, v.method, v_rev_entry,
          v.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev_voucher;

  update vouchers set status = 'void', reversed_by = v_rev_voucher, void_reason = p_reason where id = v.id;

  return v_rev_voucher;
end;
$$;

revoke all on function create_voucher(uuid,text,date,text,uuid,uuid,jsonb,numeric,text) from public, anon;
revoke all on function post_voucher(uuid) from public, anon;
revoke all on function void_voucher(uuid,date,text) from public, anon;
grant execute on function create_voucher(uuid,text,date,text,uuid,uuid,jsonb,numeric,text) to authenticated;
grant execute on function post_voucher(uuid) to authenticated;
grant execute on function void_voucher(uuid,date,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions catalog + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('vouchers.write', 'accounting', 'إنشاء وتعديل سندات مسودة', false),
  ('vouchers.post',  'accounting', 'ترحيل وإلغاء السندات',      true)
on conflict (key) do nothing;

-- give existing owner/accountant roles the new permissions retroactively
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('vouchers.write','vouchers.post')
on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('vouchers.write','vouchers.post')
on conflict do nothing;

alter table vouchers      enable row level security;
alter table voucher_lines enable row level security;

create policy voucher_select on vouchers for select using (app.is_member(org_id));
create policy voucher_write  on vouchers for all
  using (app.has_permission(org_id, 'vouchers.write'))
  with check (app.has_permission(org_id, 'vouchers.write'));

create policy voucher_line_select on voucher_lines for select using (app.is_member(org_id));
create policy voucher_line_write  on voucher_lines for all
  using (app.has_permission(org_id, 'vouchers.write'))
  with check (app.has_permission(org_id, 'vouchers.write'));

create trigger set_updated_at before update on vouchers for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on vouchers for each row execute function app.tg_audit();
