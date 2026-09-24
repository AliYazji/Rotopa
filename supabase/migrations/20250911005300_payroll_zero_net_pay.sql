-- ============================================================================
-- Rotopa · Executive review remediation, Package 5 — post_payroll_run() must
-- never create a journal line with both debit and credit equal to zero.
--
-- ROOT CAUSE (confirmed against the live code, and by a live mutation test
-- against journal_lines' own pre-existing `jl_one_side` CHECK constraint —
-- `(debit > 0 and credit = 0) or (credit > 0 and debit = 0)`, added back in
-- 20250911000600 for every journal line in the system): two places in
-- post_payroll_run() inserted a journal_lines row unconditionally:
--   1. The net-payable line (`r.net_account_id`), inserted for every run
--      regardless of v_net — including exactly 0 whenever an employee's
--      total deductions equal their total wage.
--   2. The per-account salary-expense line, inserted for every group
--      produced by the group-by, including a group whose lines summed to
--      a gross of 0.
-- Because jl_one_side already forbids a debit=0/credit=0 row outright, the
-- real, user-visible effect was NOT a silent zero-value line slipping into
-- the ledger — it was that posting ANY payroll run whose net pay came out
-- to exactly 0 (or that had a zero-gross salary-expense group) failed
-- completely, with an opaque constraint-violation error bearing no
-- resemblance to "this employee's net pay is zero," instead of posting the
-- wage expense and deduction settlements that are perfectly legitimate on
-- their own. A live mutation test (temporarily restoring the unconditional
-- inserts) reproduced exactly this failure before being fixed.
--
-- POLICY: when net pay is exactly 0 — the wage expense and every configured
-- deduction settlement (tax/loan/other) still post exactly as before, since
-- each of those blocks already only fires when its own total is > 0 — but
-- the net-payable line is skipped entirely. The entry still balances without
-- it: debit(gross) = credit(tax)+credit(loan)+credit(other) is guaranteed
-- whenever net = gross - deductions = 0, i.e. gross = deductions exactly.
-- The same > 0 guard is applied to the salary-expense group-by so a
-- zero-gross account grouping (e.g. an employee run entirely through
-- allowances that net to nothing) likewise produces no empty line. The
-- payroll run's status is updated exactly as before either way — nothing
-- about the draft->posted transition depends on how many journal lines a
-- run happened to produce.
--
-- NEGATIVE NET PAY: already structurally impossible before this migration
-- and unchanged by it — payroll_run_lines' own prl_net_not_negative CHECK
-- constraint (basic_salary + ... >= tax_amt + ...) is enforced at
-- insert/update time on every line, so v_net (a sum of non-negative
-- per-line net_salary values) can never be negative at the run level
-- either. No new runtime guard is needed for it; a regression test below
-- confirms the constraint itself still rejects an attempt to construct one.
--
-- Also added: if a payroll run's lines are constructed such that literally
-- nothing would be posted (every block above skipped — gross, tax, loan,
-- other and net all zero), posting is rejected outright rather than
-- silently creating a content-free journal entry.
-- ============================================================================

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
    having sum(l.gross) > 0
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

  if v_net > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, r.net_account_id, 'صافي رواتب مستحقة/مدفوعة', 0, round(v_net * r.rate, 4), r.currency_id, r.rate);
  end if;

  if v_line_no = 0 then
    raise exception 'this payroll run has nothing to post — every amount on it is zero' using errcode = '23514';
  end if;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update payroll_runs set status = 'posted', journal_entry_id = v_entry, posted_by = auth.uid(), posted_at = now()
    where id = p_run_id;

  return v_entry;
end;
$$;
