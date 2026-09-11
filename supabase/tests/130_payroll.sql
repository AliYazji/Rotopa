-- Payroll: Dr salary expense (grouped, with per-line override), Cr each
-- deduction type's own account only when its total > 0, Cr net payable;
-- void reverses + mirrors; guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('a1000000-0000-0000-0001-000000000001','payroll@test');
select set_config('request.jwt.claim.sub','a1000000-0000-0000-0001-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PRORG','مؤسسة اختبار الرواتب','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_exp uuid; v_exp2 uuid; v_tax uuid; v_loan uuid; v_other uuid; v_net uuid;
  v_emp1 uuid; v_emp2 uuid; v_acc1 uuid; v_acc2 uuid;
  v_run1 uuid; v_run2 uuid; v_entry uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EXP','مصروف رواتب',v_parent,true,'debit') returning id into v_exp;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EXP2','مصروف رواتب - إدارة',v_parent,true,'debit') returning id into v_exp2;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'TAX','ضريبة دخل مستحقة',v_parent,true,'credit') returning id into v_tax;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'LOAN','سلف موظفين',v_parent,true,'debit') returning id into v_loan;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'OTHDED','استقطاعات أخرى',v_parent,true,'credit') returning id into v_other;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'NET','رواتب مستحقة الدفع',v_parent,true,'credit') returning id into v_net;

  insert into dealers (org_id, code, name_ar, is_employee, account_id) values (v_org,'E1','موظف واحد',true,v_loan) returning id into v_emp1;
  insert into dealers (org_id, code, name_ar, is_employee, account_id) values (v_org,'E2','موظف اثنين',true,v_loan) returning id into v_emp2;

  -- 1) basic run: emp1 basic 1000 + transport 100, tax 50; emp2 basic 2000, loan 200
  --    gross = 1000+100+2000 = 3100; deductions = 50+200 = 250; net = 2850
  v_run1 := create_payroll_run(v_org, current_date, 'رواتب شهر الاختبار',
    jsonb_build_array(
      jsonb_build_object('dealer_id', v_emp1, 'basic_salary', 1000, 'transportation_amt', 100, 'tax_amt', 50),
      jsonb_build_object('dealer_id', v_emp2, 'basic_salary', 2000, 'loan_amount', 200)
    ),
    v_net, 'payable', v_exp, v_tax, v_loan, v_other);

  -- posting without the required tax account configured should fail if tax > 0... here it IS configured, so this should succeed
  v_entry := post_payroll_run(v_run1);
  assert account_balance(v_exp) = 3100, 'salary expense should be debited the full gross (3100)';
  assert account_balance(v_tax) = -50, 'tax payable should be credited 50';
  assert account_balance(v_loan) = -200, 'loan receivable should be credited (reduced) 200';
  assert account_balance(v_net) = -2850, 'net payable should be credited 2850';
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'payroll entry must balance';
  assert (select net_salary from payroll_run_lines where run_id = v_run1 and dealer_id = v_emp1) = 1050, 'emp1 net should be 1050 (1100-50)';
  assert (select net_salary from payroll_run_lines where run_id = v_run1 and dealer_id = v_emp2) = 1800, 'emp2 net should be 1800 (2000-200)';

  -- 2) per-line salary_expense_account_id overrides the run default, grouped separately
  v_run2 := create_payroll_run(v_org, current_date, 'رواتب دفعة ثانية',
    jsonb_build_array(
      jsonb_build_object('dealer_id', v_emp1, 'salary_expense_account_id', v_exp2, 'basic_salary', 500)
    ),
    v_net, 'payable', v_exp);
  perform post_payroll_run(v_run2);
  assert account_balance(v_exp2) = 500, 'override account should be debited, not the run default';
  assert account_balance(v_exp) = 3100, 'run default account should be unaffected by the overridden line';

  -- 3) posting is rejected when a deduction is used but its account was never configured
  declare v_run3 uuid;
  begin
    v_run3 := create_payroll_run(v_org, current_date, 'رواتب بلا حساب ضريبة',
      jsonb_build_array(jsonb_build_object('dealer_id', v_emp1, 'basic_salary', 100, 'tax_amt', 10)),
      v_net, 'payable', v_exp);  -- no tax_payable_account_id given
    begin
      perform post_payroll_run(v_run3);
      raise exception 'TEST FAIL: posted a run with tax deductions but no tax account configured';
    exception when sqlstate '23514' then null;
    end;
  end;

  -- 4) void the first run: reverses the entry and mirrors a new void document
  declare v_void uuid;
  begin
    v_void := void_payroll_run(v_run1, current_date, 'اختبار الإلغاء');
    assert (select status from payroll_runs where id = v_run1) = 'void', 'run should be void';
    assert (select status from payroll_runs where id = v_void) = 'posted', 'mirrored void document should be posted';
    -- run1's 3100 fully reverses out of v_exp; run2 posted to v_exp2 instead, so v_exp nets to 0
    assert account_balance(v_exp) = 0, 'salary expense should net back to 0 — only run1 ever touched it, and it''s now voided';
    assert account_balance(v_tax) = 0, 'tax payable should net back to 0';
    assert account_balance(v_loan) = 0, 'loan receivable should net back to 0';
    -- run2 (never voided) also credited v_net by its own 500 net salary,
    -- so it doesn't net to 0 like the others — it nets to just run2's effect
    assert account_balance(v_net) = -500, 'net payable should net back to just run2''s unvoided 500';
  end;

  -- 5) posted run is immutable
  begin
    update payroll_runs set description = 'tampered' where id = v_run2;
    raise exception 'TEST FAIL: edited a posted payroll run';
  exception when sqlstate '23514' then null;
  end;

  -- 6) posted run cannot be deleted, only voided
  begin
    delete from payroll_runs where id = v_run2;
    raise exception 'TEST FAIL: deleted a posted payroll run';
  exception when sqlstate '23514' then null;
  end;

  -- 7) a dealer that is not an employee cannot appear on a payroll run
  declare v_cust uuid; v_cust_acc uuid;
  begin
    insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_cust_acc;
    insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_cust_acc) returning id into v_cust;
    begin
      perform create_payroll_run(v_org, current_date, 'محاولة خاطئة',
        jsonb_build_array(jsonb_build_object('dealer_id', v_cust, 'basic_salary', 100)),
        v_net, 'payable', v_exp);
      raise exception 'TEST FAIL: created a payroll run for a non-employee';
    exception when sqlstate '23514' then null;
    end;
  end;

  raise notice 'PAYROLL OK';
end $$;

rollback;
