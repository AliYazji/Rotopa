-- ============================================================================
-- Rotopa · Cash drawer shifts (وردية الصندوق) — the highest-priority real
-- gap flagged by this session's system audit: the legacy backup's
-- CashControlTb (denomination counting, open/close a till, over/short) has
-- 1,314 real rows — clearly a genuine daily-use feature — and nothing like
-- it existed anywhere in this rebuild until now.
--
-- Design: open_cash_shift() snapshots a denomination count + the cash
-- account's own GL balance at that moment; close_cash_shift() counts again,
-- and the EXPECTED closing amount is derived as a DELTA —
--   opening_count + (closing_gl_balance - opening_gl_balance)
-- — rather than trusting the GL's cumulative balance directly. This isolates
-- THIS shift's own variance regardless of any earlier, unrelated drift in
-- the account's all-time balance. A nonzero variance posts a normal journal
-- entry against a caller-chosen account (debit the shortage expense account
-- already seeded at 53701 "عجز الصندوق والنقدية", or credit the overage
-- income account at 65104 "زيادة الصندوق والنقدية" — both already exist
-- from 20250911003800_default_coa.sql, just never had anything to post to
-- them before now) — same "only require an account when actually needed"
-- idiom already used for VAT.
--
-- cashier_dealer_id (an is_employee=true dealer, chosen at open) plus
-- sales_invoices.cash_shift_id (best-effort auto-linked by the web layer
-- when a cash sale happens while a shift is open on that same cash account)
-- is what lets the print layout show which cashier rang up a given sale —
-- the user asked for this explicitly alongside the shift feature itself.
-- ============================================================================

create table cash_shifts (
  id                    uuid primary key default extensions.gen_random_uuid(),
  org_id                uuid not null references organizations(id) on delete restrict,
  shift_no              bigint not null,
  cash_account_id       uuid not null references accounts(id) on delete restrict,
  cashier_dealer_id     uuid references dealers(id) on delete restrict,
  status                text not null default 'open' check (status in ('open','closed')),

  opened_at             timestamptz not null default now(),
  opened_by             uuid references auth.users(id),
  opening_total         numeric(19,4) not null default 0,
  opening_denominations jsonb not null default '{}'::jsonb,
  opening_gl_balance    numeric(19,4) not null,

  closed_at             timestamptz,
  closed_by             uuid references auth.users(id),
  closing_total         numeric(19,4),
  closing_denominations jsonb,
  closing_gl_balance    numeric(19,4),
  expected_closing      numeric(19,4),
  variance              numeric(19,4),
  variance_journal_entry_id uuid references journal_entries(id) on delete restrict,

  notes                 text not null default '',
  updated_at            timestamptz not null default now(),

  unique (org_id, shift_no),
  constraint cash_shift_closed_has_totals check (
    status = 'open' or (closed_at is not null and closing_total is not null)
  )
);
create index on cash_shifts (org_id, cash_account_id, status);

alter table cash_shifts enable row level security;
create policy cash_shift_select on cash_shifts for select using (app.is_member(org_id));
-- writes go exclusively through open_cash_shift()/close_cash_shift() (both
-- SECURITY DEFINER, bypassing RLS internally) — only a plain delete of an
-- accidentally-opened shift is allowed directly
create policy cash_shift_delete on cash_shifts for delete
  using (app.has_permission(org_id, 'cash_shifts.write') and status = 'open');

create trigger set_updated_at before update on cash_shifts for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on cash_shifts for each row execute function app.tg_audit();

create or replace function app.tg_cash_shift_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'closed' then
    raise exception 'a closed cash shift cannot be modified' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger cash_shift_guard before update on cash_shifts for each row execute function app.tg_cash_shift_guard();

-- ---------------------------------------------------------------------------
-- open_cash_shift()
-- ---------------------------------------------------------------------------
create or replace function open_cash_shift(
  p_org uuid,
  p_cash_account_id uuid,
  p_denominations jsonb default '{}'::jsonb,   -- {"<denomination>": <count>, ...}
  p_cashier_dealer_id uuid default null,
  p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_total numeric(19,4);
  v_acc accounts%rowtype;
begin
  perform app.require_permission(p_org, 'cash_shifts.write');

  select * into v_acc from accounts where id = p_cash_account_id;
  if not found or v_acc.org_id <> p_org then
    raise exception 'cash account not found in this organization' using errcode = '23503';
  end if;
  if not v_acc.is_postable then
    raise exception 'account % is a group account and cannot be used as a cash drawer', v_acc.code using errcode = '23514';
  end if;

  if p_cashier_dealer_id is not null and not exists (
    select 1 from dealers where id = p_cashier_dealer_id and org_id = p_org and is_employee
  ) then
    raise exception 'cashier must be an employee dealer in this organization' using errcode = '23503';
  end if;

  if exists (select 1 from cash_shifts where org_id = p_org and cash_account_id = p_cash_account_id and status = 'open') then
    raise exception 'this cash drawer already has an open shift' using errcode = '23514';
  end if;

  select coalesce(sum((kv.key)::numeric * (kv.value)::numeric), 0) into v_total
  from jsonb_each_text(coalesce(p_denominations, '{}'::jsonb)) kv;

  insert into cash_shifts (org_id, shift_no, cash_account_id, cashier_dealer_id, opened_by,
                            opening_total, opening_denominations, opening_gl_balance, notes)
  values (p_org, app.next_seq(p_org, 'cash_shift'), p_cash_account_id, p_cashier_dealer_id, auth.uid(),
          v_total, coalesce(p_denominations, '{}'::jsonb), account_balance(p_cash_account_id), coalesce(p_notes, ''))
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- close_cash_shift() — posts the variance (if any) as a normal journal entry
-- ---------------------------------------------------------------------------
create or replace function close_cash_shift(
  p_shift_id uuid,
  p_denominations jsonb default '{}'::jsonb,
  p_variance_account_id uuid default null,
  p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  s cash_shifts%rowtype;
  v_total numeric(19,4);
  v_close_gl numeric(19,4);
  v_expected numeric(19,4);
  v_variance numeric(19,4);
  v_entry uuid;
  v_period uuid;
  v_no int := 0;
  v_base_currency uuid;
  v_acc_org uuid;
begin
  select * into s from cash_shifts where id = p_shift_id for update;
  if not found then raise exception 'shift not found' using errcode = 'P0002'; end if;
  perform app.require_permission(s.org_id, 'cash_shifts.post');
  if s.status <> 'open' then
    raise exception 'only an open shift can be closed (this one is %)', s.status using errcode = '23514';
  end if;

  select coalesce(sum((kv.key)::numeric * (kv.value)::numeric), 0) into v_total
  from jsonb_each_text(coalesce(p_denominations, '{}'::jsonb)) kv;

  v_close_gl := account_balance(s.cash_account_id);
  v_expected := s.opening_total + (v_close_gl - s.opening_gl_balance);
  v_variance := round(v_total - v_expected, 4);

  if v_variance <> 0 then
    if p_variance_account_id is null then
      raise exception 'a variance account is required — counted cash does not match the expected amount (variance %)', v_variance
        using errcode = '23514';
    end if;
    select org_id into v_acc_org from accounts where id = p_variance_account_id;
    if v_acc_org is distinct from s.org_id then
      raise exception 'variance account belongs to a different organization' using errcode = '23503';
    end if;
    v_base_currency := (select base_currency_id from organizations where id = s.org_id);
    v_period := app.open_period_for(s.org_id, current_date);

    insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                  source_type, source_id, document_currency_id, created_by)
    values (s.org_id, app.next_seq(s.org_id, 'journal'), current_date, v_period,
            'تسوية جرد صندوق — وردية رقم ' || s.shift_no, 'cash_shift', s.id, v_base_currency, auth.uid())
    returning id into v_entry;

    if v_variance < 0 then
      v_no := v_no + 1;
      insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
      values (v_entry, v_no, p_variance_account_id, 'عجز صندوق — وردية رقم ' || s.shift_no, abs(v_variance), 0, v_base_currency, 1);
      v_no := v_no + 1;
      insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
      values (v_entry, v_no, s.cash_account_id, 'عجز صندوق — وردية رقم ' || s.shift_no, 0, abs(v_variance), v_base_currency, 1);
    else
      v_no := v_no + 1;
      insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
      values (v_entry, v_no, s.cash_account_id, 'زيادة صندوق — وردية رقم ' || s.shift_no, v_variance, 0, v_base_currency, 1);
      v_no := v_no + 1;
      insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
      values (v_entry, v_no, p_variance_account_id, 'زيادة صندوق — وردية رقم ' || s.shift_no, 0, v_variance, v_base_currency, 1);
    end if;

    update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  end if;

  update cash_shifts set
    status = 'closed', closed_at = now(), closed_by = auth.uid(),
    closing_total = v_total, closing_denominations = coalesce(p_denominations, '{}'::jsonb),
    closing_gl_balance = v_close_gl, expected_closing = v_expected, variance = v_variance,
    variance_journal_entry_id = v_entry,
    notes = case when coalesce(p_notes,'') <> '' then s.notes || case when s.notes <> '' then E'\n' else '' end || p_notes else s.notes end
  where id = p_shift_id;

  return p_shift_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- sales_invoices gains an optional link to the shift it was rung up under —
-- lets the print layout show which cashier handled a given sale. Never
-- required: a cash sale with no open shift on its cash account still posts
-- exactly as before.
-- ---------------------------------------------------------------------------
alter table sales_invoices add column cash_shift_id uuid references cash_shifts(id) on delete restrict;

-- ---------------------------------------------------------------------------
-- create_sales_invoice() — same as the true latest body (20250911002600),
-- plus the one new optional parameter. Adding a parameter changes the
-- function's identity (name + arg TYPES) as far as Postgres is concerned —
-- `create or replace` on a longer parameter list does NOT replace the old
-- 11-parameter version, it silently creates a SECOND overload alongside it
-- (the exact same "app.vat_rate() zombie overload" class of bug this
-- session already found once this session's own audit and had to fix with
-- 20250911003600_integrity_fixes.sql). Drop the old signature explicitly
-- first so this stays a true replace, not a duplicate.
-- ---------------------------------------------------------------------------
drop function if exists create_sales_invoice(uuid, date, uuid, uuid, jsonb, uuid, numeric, text, uuid, text, date);

create or replace function create_sales_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct, unit_id}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default '', p_due_date date default null,
  p_cash_shift_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_invoice uuid; v_line jsonb; v_no int := 0;
  v_currency uuid; v_is_customer boolean;
begin
  perform app.require_permission(p_org, 'sales.write');

  select is_customer into v_is_customer from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_customer is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_customer then raise exception 'dealer is not marked as a customer' using errcode = '23514'; end if;

  if p_cash_shift_id is not null and not exists (
    select 1 from cash_shifts where id = p_cash_shift_id and org_id = p_org and status = 'open'
  ) then
    raise exception 'cash shift not found, not open, or belongs to a different organization' using errcode = '23503';
  end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into sales_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                               payment_method, cash_account_id, description, due_date, created_by, cash_shift_id)
  values (p_org, app.next_seq(p_org, 'sales_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), coalesce(p_due_date, p_invoice_date), auth.uid(), p_cash_shift_id)
  returning id into v_invoice;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into sales_invoice_lines (invoice_id, line_no, item_id, qty, unit_price, discount_pct, unit_id)
    values (v_invoice, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0), (v_line->>'unit_id')::uuid);
  end loop;

  return v_invoice;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions — 'write' opens a shift, 'post' closes one (posts the
-- variance entry, matching every other draft->post permission split in
-- this project). Retroactively granted to owner/accountant for orgs that
-- already existed before this migration (same skip_role_guard + explicit
-- transaction pattern this session already had to learn twice).
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('cash_shifts.write', 'accounting', 'فتح وردية صندوق جديدة', false),
  ('cash_shifts.post',  'accounting', 'إغلاق وردية صندوق وترحيل فرق الجرد إن وجد', true)
on conflict (key) do nothing;

begin;
select set_config('app.skip_role_guard', 'on', true);
insert into role_permissions (role_id, permission_key)
  select r.id, p.key from roles r cross join permissions p
  where r.code = 'owner' and p.key in ('cash_shifts.write','cash_shifts.post')
  on conflict do nothing;
insert into role_permissions (role_id, permission_key)
  select r.id, p.key from roles r cross join permissions p
  where r.code = 'accountant' and p.key in ('cash_shifts.write','cash_shifts.post')
  on conflict do nothing;
select set_config('app.skip_role_guard', 'off', true);
commit;
