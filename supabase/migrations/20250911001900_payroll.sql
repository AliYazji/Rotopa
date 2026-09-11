-- ============================================================================
-- Rotopa · Module 14 — Payroll
--
-- Legacy shape: employee_salary_master (one row per pay run, header) +
-- employee_salary_tb (one row per employee in that run) + Create_Salary_JV
-- (one posted JV per run). Same draft→posted→void lifecycle as every other
-- multi-line document (sales/purchase invoices) — unlike module 13's fixed
-- assets, a payroll run genuinely has lines built up before posting.
--
-- Deliberately dropped from the legacy shape (documented, not silently
-- lost): per-employee income-tax exemption inputs (children/spouse/
-- academic-degree/supporter counts, exemption amount) — real Palestinian/
-- Libyan tax-law calculations this rebuild doesn't encode yet; the legacy
-- tax_amt column itself IS kept (whatever number the accountant enters),
-- just not auto-computed from dependents. Also dropped: hourly/daily-rate
-- inputs (work_Day/work_Hour/salary_Day) — salary components are entered
-- as amounts, not computed from a rate table. The four legacy misc-
-- deduction columns (discount/discount2/discount3/discountFood) collapse
-- into one GL bucket at posting (still four separate input columns, for
-- exact legacy-data-entry parity) — see post_payroll_run()'s comment.
-- ============================================================================

create table payroll_runs (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  run_no        bigint not null,
  run_date      date not null,
  description   text not null default '',
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),

  payment_method text not null default 'payable' check (payment_method in ('cash','payable')),
  net_account_id            uuid not null references accounts(id) on delete restrict,  -- cash/bank (payment_method='cash') or a salaries-payable liability (payment_method='payable')
  default_salary_expense_account_id uuid references accounts(id) on delete restrict,   -- used only for a line with no salary_expense_account_id of its own
  tax_payable_account_id     uuid references accounts(id) on delete restrict,          -- required at posting only if any line has tax_amt > 0
  loan_receivable_account_id uuid references accounts(id) on delete restrict,          -- required at posting only if any line has loan_amount > 0
  other_deductions_account_id uuid references accounts(id) on delete restrict,         -- required at posting only if any line has discount/discount2/discount3/discount_food > 0

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  void_of       uuid references payroll_runs(id) on delete restrict,
  reversed_by   uuid references payroll_runs(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, run_no),
  constraint pr_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on payroll_runs (org_id, run_date);
create index on payroll_runs (org_id, status);

create table payroll_run_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  run_id        uuid not null references payroll_runs(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  dealer_id     uuid not null references dealers(id) on delete restrict,   -- the employee (dealers.is_employee = true)
  salary_expense_account_id uuid references accounts(id) on delete restrict,  -- null = use the run's default

  -- additions
  basic_salary      numeric(19,4) not null default 0 check (basic_salary >= 0),
  transportation_amt numeric(19,4) not null default 0 check (transportation_amt >= 0),
  housing_amt       numeric(19,4) not null default 0 check (housing_amt >= 0),
  overtime_amt      numeric(19,4) not null default 0 check (overtime_amt >= 0),
  other_additions   numeric(19,4) not null default 0 check (other_additions >= 0),
  gross numeric(19,4) generated always as
    (basic_salary + transportation_amt + housing_amt + overtime_amt + other_additions) stored,

  -- deductions
  tax_amt       numeric(19,4) not null default 0 check (tax_amt >= 0),
  loan_amount   numeric(19,4) not null default 0 check (loan_amount >= 0),
  discount      numeric(19,4) not null default 0 check (discount >= 0),
  discount2     numeric(19,4) not null default 0 check (discount2 >= 0),
  discount3     numeric(19,4) not null default 0 check (discount3 >= 0),
  discount_food numeric(19,4) not null default 0 check (discount_food >= 0),
  deductions numeric(19,4) generated always as
    (tax_amt + loan_amount + discount + discount2 + discount3 + discount_food) stored,

  net_salary numeric(19,4) generated always as
    (basic_salary + transportation_amt + housing_amt + overtime_amt + other_additions
     - tax_amt - loan_amount - discount - discount2 - discount3 - discount_food) stored,

  notes text not null default '',

  unique (run_id, line_no),
  constraint prl_net_not_negative check (
    basic_salary + transportation_amt + housing_amt + overtime_amt + other_additions
    >= tax_amt + loan_amount + discount + discount2 + discount3 + discount_food
  )
);
create index on payroll_run_lines (run_id);
create index on payroll_run_lines (org_id, dealer_id);

-- ---------------------------------------------------------------------------
-- Validation & guards — same shape as sales_invoice_lines/sales_invoices
-- ---------------------------------------------------------------------------
create or replace function app.tg_payroll_run_line_validate()
returns trigger language plpgsql as $$
declare r payroll_runs%rowtype; d dealers%rowtype;
begin
  select * into r from payroll_runs where id = new.run_id;
  if not found then raise exception 'payroll line references a missing run' using errcode = '23503'; end if;
  if r.status <> 'draft' then
    raise exception 'payroll run % is %; its lines are frozen', r.run_no, r.status using errcode = '23514';
  end if;
  new.org_id := r.org_id;

  select * into d from dealers where id = new.dealer_id;
  if d.org_id <> r.org_id then raise exception 'employee belongs to a different organization' using errcode = '23503'; end if;
  if not d.is_employee then raise exception 'dealer % is not marked as an employee', d.code using errcode = '23514'; end if;

  return new;
end;
$$;
create trigger payroll_run_line_validate
  before insert or update on payroll_run_lines
  for each row execute function app.tg_payroll_run_line_validate();

create or replace function app.tg_payroll_run_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from payroll_runs where id = old.run_id;
  if v_status <> 'draft' then raise exception 'payroll run is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger payroll_run_line_frozen_del
  before delete on payroll_run_lines
  for each row execute function app.tg_payroll_run_line_frozen();

create or replace function app.tg_payroll_run_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then raise exception 'a void payroll run cannot be modified' using errcode = '23514'; end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.run_no <> old.run_no or new.run_date <> old.run_date then
      raise exception 'a posted payroll run is immutable; reverse it with void_payroll_run()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger payroll_run_guard before update on payroll_runs for each row execute function app.tg_payroll_run_guard();

create trigger set_updated_at before update on payroll_runs for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on payroll_runs for each row execute function app.tg_audit();

create trigger block_delete_unless_draft
  before delete on payroll_runs
  for each row execute function app.tg_block_delete_unless_draft();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_payroll_run(
  p_org uuid, p_run_date date, p_description text,
  p_lines jsonb,   -- [{dealer_id, salary_expense_account_id, basic_salary, transportation_amt, housing_amt, overtime_amt, other_additions, tax_amt, loan_amount, discount, discount2, discount3, discount_food, notes}]
  p_net_account_id uuid, p_payment_method text default 'payable',
  p_default_salary_expense_account_id uuid default null,
  p_tax_payable_account_id uuid default null, p_loan_receivable_account_id uuid default null,
  p_other_deductions_account_id uuid default null,
  p_currency_id uuid default null, p_rate numeric default 1
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_run uuid; v_line jsonb; v_no int := 0; v_currency uuid;
begin
  perform app.require_permission(p_org, 'payroll.write');

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into payroll_runs (org_id, run_no, run_date, description, currency_id, rate, payment_method,
                             net_account_id, default_salary_expense_account_id, tax_payable_account_id,
                             loan_receivable_account_id, other_deductions_account_id, created_by)
  values (p_org, app.next_seq(p_org, 'payroll_run'), p_run_date, coalesce(p_description,''), v_currency,
          coalesce(p_rate, 1), coalesce(p_payment_method,'payable'), p_net_account_id,
          p_default_salary_expense_account_id, p_tax_payable_account_id, p_loan_receivable_account_id,
          p_other_deductions_account_id, auth.uid())
  returning id into v_run;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into payroll_run_lines (run_id, line_no, dealer_id, salary_expense_account_id,
                                    basic_salary, transportation_amt, housing_amt, overtime_amt, other_additions,
                                    tax_amt, loan_amount, discount, discount2, discount3, discount_food, notes)
    values (
      v_run, v_no, (v_line->>'dealer_id')::uuid, nullif(v_line->>'salary_expense_account_id','')::uuid,
      coalesce((v_line->>'basic_salary')::numeric, 0), coalesce((v_line->>'transportation_amt')::numeric, 0),
      coalesce((v_line->>'housing_amt')::numeric, 0), coalesce((v_line->>'overtime_amt')::numeric, 0),
      coalesce((v_line->>'other_additions')::numeric, 0),
      coalesce((v_line->>'tax_amt')::numeric, 0), coalesce((v_line->>'loan_amount')::numeric, 0),
      coalesce((v_line->>'discount')::numeric, 0), coalesce((v_line->>'discount2')::numeric, 0),
      coalesce((v_line->>'discount3')::numeric, 0), coalesce((v_line->>'discount_food')::numeric, 0),
      coalesce(v_line->>'notes', '')
    );
  end loop;

  return v_run;
end;
$$;

-- Dr salary expense per line (grouped by account, falling back to the
-- run's default), Cr each deduction TYPE's own account (only when its
-- total is > 0 — most runs won't use all three), Cr the net payable
-- account for what's actually owed/paid. The four legacy misc-deduction
-- columns (discount/discount2/discount3/discountFood) share ONE GL bucket
-- here (other_deductions_account_id) — kept as separate INPUT columns for
-- legacy-data-entry parity, but the chart of accounts doesn't need four
-- near-identical "other payroll deduction" accounts to tell them apart.
create or replace function post_payroll_run(p_run_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r payroll_runs%rowtype;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_tax numeric(19,4);
  v_loan numeric(19,4);
  v_other numeric(19,4);
  v_net numeric(19,4);
  g record;
begin
  select * into r from payroll_runs where id = p_run_id for update;
  if not found then raise exception 'payroll run not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'payroll.post');
  if r.status <> 'draft' then
    raise exception 'only a draft payroll run can be posted (this one is %)', r.status using errcode = '23514';
  end if;
  if not exists (select 1 from payroll_run_lines where run_id = p_run_id) then
    raise exception 'payroll run has no lines' using errcode = '23514';
  end if;

  select coalesce(sum(tax_amt), 0), coalesce(sum(loan_amount), 0),
         coalesce(sum(discount + discount2 + discount3 + discount_food), 0), coalesce(sum(net_salary), 0)
    into v_tax, v_loan, v_other, v_net
  from payroll_run_lines where run_id = p_run_id;

  if v_tax > 0 and r.tax_payable_account_id is null then
    raise exception 'a tax payable account is required — this run has tax deductions' using errcode = '23514';
  end if;
  if v_loan > 0 and r.loan_receivable_account_id is null then
    raise exception 'a loan receivable account is required — this run has loan deductions' using errcode = '23514';
  end if;
  if v_other > 0 and r.other_deductions_account_id is null then
    raise exception 'an other-deductions account is required — this run has misc deductions' using errcode = '23514';
  end if;

  v_period := app.open_period_for(r.org_id, r.run_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.run_date, v_period,
          coalesce(nullif(r.description,''), 'كشف رواتب رقم ' || r.run_no),
          'payroll_run', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  for g in
    select coalesce(l.salary_expense_account_id, r.default_salary_expense_account_id) acc, sum(l.gross) amt
    from payroll_run_lines l where l.run_id = p_run_id
    group by coalesce(l.salary_expense_account_id, r.default_salary_expense_account_id)
  loop
    if g.acc is null then
      raise exception 'an employee on this run has no salary expense account and no default was given' using errcode = '23514';
    end if;
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'رواتب — كشف رقم ' || r.run_no, round(g.amt * r.rate, 4), 0, r.currency_id, r.rate);
  end loop;

  if v_tax > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, r.tax_payable_account_id, 'ضريبة دخل مستقطعة', 0, round(v_tax * r.rate, 4), r.currency_id, r.rate);
  end if;
  if v_loan > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, r.loan_receivable_account_id, 'استقطاع سلف موظفين', 0, round(v_loan * r.rate, 4), r.currency_id, r.rate);
  end if;
  if v_other > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, r.other_deductions_account_id, 'استقطاعات أخرى', 0, round(v_other * r.rate, 4), r.currency_id, r.rate);
  end if;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  values (v_entry, v_line_no, r.net_account_id, 'صافي رواتب مستحقة/مدفوعة', 0, round(v_net * r.rate, 4), r.currency_id, r.rate);

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update payroll_runs set status = 'posted', journal_entry_id = v_entry, posted_by = auth.uid(), posted_at = now()
    where id = p_run_id;

  return v_entry;
end;
$$;

create or replace function void_payroll_run(p_run_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r payroll_runs%rowtype;
  v_entry uuid;
  v_period uuid;
  v_rev uuid;
begin
  select * into r from payroll_runs where id = p_run_id for update;
  if not found then raise exception 'payroll run not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'payroll.post');
  if r.status <> 'posted' then raise exception 'only a posted payroll run can be voided' using errcode = '23514'; end if;

  v_period := app.open_period_for(r.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), p_date, v_period,
          'إلغاء كشف رواتب رقم ' || r.run_no || coalesce(' — ' || p_reason, ''),
          'reversal', r.journal_entry_id, r.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate
  from journal_lines where entry_id = r.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = r.journal_entry_id;

  insert into payroll_runs (org_id, run_no, run_date, description, currency_id, rate, payment_method,
                             net_account_id, default_salary_expense_account_id, tax_payable_account_id,
                             loan_receivable_account_id, other_deductions_account_id,
                             journal_entry_id, void_of, status, created_by, posted_by, posted_at)
  values (r.org_id, app.next_seq(r.org_id, 'payroll_run'), p_date, 'إلغاء كشف رواتب رقم ' || r.run_no,
          r.currency_id, r.rate, r.payment_method, r.net_account_id, r.default_salary_expense_account_id,
          r.tax_payable_account_id, r.loan_receivable_account_id, r.other_deductions_account_id,
          v_entry, r.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update payroll_runs set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = r.id;

  return v_rev;
end;
$$;

revoke all on function create_payroll_run(uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,uuid,uuid,numeric) from public, anon;
revoke all on function post_payroll_run(uuid) from public, anon;
revoke all on function void_payroll_run(uuid,date,text) from public, anon;
grant execute on function create_payroll_run(uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,uuid,uuid,numeric) to authenticated;
grant execute on function post_payroll_run(uuid) to authenticated;
grant execute on function void_payroll_run(uuid,date,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('payroll.write', 'hr', 'إنشاء وتعديل كشوف رواتب مسودة', false),
  ('payroll.post',  'hr', 'ترحيل وإلغاء كشوف الرواتب',      true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('payroll.write','payroll.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('payroll.write','payroll.post') on conflict do nothing;

alter table payroll_runs      enable row level security;
alter table payroll_run_lines enable row level security;

create policy payroll_run_select on payroll_runs for select using (app.is_member(org_id));
create policy payroll_run_write  on payroll_runs for all
  using (app.has_permission(org_id, 'payroll.write')) with check (app.has_permission(org_id, 'payroll.write'));

create policy payroll_run_line_select on payroll_run_lines for select using (app.is_member(org_id));
create policy payroll_run_line_write  on payroll_run_lines for all
  using (app.has_permission(org_id, 'payroll.write')) with check (app.has_permission(org_id, 'payroll.write'));
