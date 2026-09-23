-- Regression coverage for 20250911005300_payroll_zero_net_pay.sql.
--
-- Before this fix, post_payroll_run() always inserted a net-payable journal
-- line (and a salary-expense line per account group) regardless of amount.
-- Because journal_lines' own jl_one_side CHECK constraint already forbids a
-- debit=0/credit=0 row, this didn't silently pollute the ledger — it made
-- posting fail outright (an opaque constraint violation) for any run whose
-- net pay came out to exactly 0.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fb000000-0000-0000-000b-000000000001','payroll-zero@test');
select set_config('request.jwt.claim.sub','fb000000-0000-0000-000b-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PRZORG','مؤسسة اختبار صافي الراتب الصفري','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_exp uuid; v_tax uuid; v_net uuid;
  v_emp1 uuid; v_emp2 uuid;
  v_run uuid; v_entry uuid;
  v_caught boolean; v_msg text;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EXP','مصروف رواتب',v_parent,true,'debit') returning id into v_exp;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'TAX','ضريبة دخل مستحقة',v_parent,true,'credit') returning id into v_tax;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'NET','رواتب مستحقة الدفع',v_parent,true,'credit') returning id into v_net;

  insert into dealers (org_id, code, name_ar, is_employee, account_id) values (v_org,'E1','موظف واحد',true,v_tax) returning id into v_emp1;
  insert into dealers (org_id, code, name_ar, is_employee, account_id) values (v_org,'E2','موظف اثنين',true,v_tax) returning id into v_emp2;

  -- =========================================================================
  -- 1) positive net pay: unaffected by this fix — the net line still posts
  -- =========================================================================
  v_run := create_payroll_run(v_org, current_date, 'راتب موجب',
    jsonb_build_array(jsonb_build_object('dealer_id', v_emp1, 'basic_salary', 1000, 'tax_amt', 100)),
    v_net, 'payable', v_exp, v_tax);
  v_entry := post_payroll_run(v_run);
  assert account_balance(v_exp) = 1000, 'salary expense should be debited the gross (1000)';
  assert account_balance(v_tax) = -100, 'tax payable should be credited 100';
  assert account_balance(v_net) = -900, 'net payable should be credited the positive net (900)';
  assert exists (select 1 from journal_lines where entry_id = v_entry and account_id = v_net),
    'a positive net must still produce its own journal line';

  -- =========================================================================
  -- 2) zero net pay: wage exactly equals deductions — the wage expense and
  --    the deduction settlement still post, but NO journal line for the net
  --    account, and certainly no debit=0/credit=0 line anywhere
  -- =========================================================================
  v_run := create_payroll_run(v_org, current_date, 'راتب صافيه صفر',
    jsonb_build_array(jsonb_build_object('dealer_id', v_emp2, 'basic_salary', 500, 'tax_amt', 500)),
    v_net, 'payable', v_exp, v_tax);
  assert (select net_salary from payroll_run_lines where run_id = v_run) = 0, 'sanity: this line''s net salary should be exactly 0';
  v_entry := post_payroll_run(v_run);
  assert (select status from payroll_runs where id = v_run) = 'posted', 'a zero-net run must still post successfully, with the status updated consistently';

  assert account_balance(v_exp) = 1000 + 500, 'salary expense should still be debited the full gross (500) even though net is 0';
  assert account_balance(v_tax) = -100 - 500, 'tax payable should still be credited its full deduction (500) even though net is 0';
  assert not exists (select 1 from journal_lines where entry_id = v_entry and account_id = v_net),
    'a zero net must NOT produce any journal line against the net-payable account';
  assert not exists (select 1 from journal_lines where entry_id = v_entry and debit = 0 and credit = 0),
    'no journal line for this entry may have both debit and credit equal to zero';
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'the zero-net entry must still balance on its own (gross debit == deduction credits)';

  -- =========================================================================
  -- 3) negative net pay is structurally impossible — enforced by
  --    payroll_run_lines' own prl_net_not_negative CHECK constraint at
  --    insert time, not by any new runtime guard in post_payroll_run()
  -- =========================================================================
  v_caught := false; v_msg := null;
  begin
    insert into payroll_run_lines (run_id, line_no, dealer_id, basic_salary, tax_amt)
    values (v_run, 999, v_emp1, 100, 200);
  exception when check_violation then
    v_caught := true;
    get stacked diagnostics v_msg = message_text;
  end;
  assert v_caught, 'a line whose deductions exceed its additions (negative net) must be rejected at the constraint level';

  -- =========================================================================
  -- 4) a run where literally every amount is zero has nothing to post —
  --    rejected outright rather than creating a content-free journal entry
  -- =========================================================================
  declare v_run_empty uuid; begin
    v_run_empty := create_payroll_run(v_org, current_date, 'كل القيم صفر',
      jsonb_build_array(jsonb_build_object('dealer_id', v_emp1, 'basic_salary', 0)),
      v_net, 'payable', v_exp, v_tax);
    v_caught := false; v_msg := null;
    begin
      perform post_payroll_run(v_run_empty);
    exception when sqlstate '23514' then
      v_caught := true;
      get stacked diagnostics v_msg = message_text;
    end;
    assert v_caught, 'a payroll run with every amount at zero should be rejected rather than posted as an empty entry';
    assert (select status from payroll_runs where id = v_run_empty) = 'draft', 'the rejected all-zero run should remain a draft';
  end;

  raise notice 'PAYROLL ZERO NET PAY OK';
end $$;

rollback;
