-- Cheque lifecycle: incoming clear, incoming bounce, outgoing clear, guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f0000000-0000-0000-0000-000000000001','chq@test');
select set_config('request.jwt.claim.sub','f0000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('CHQORG','مؤسسة اختبار الشيكات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_base uuid := (select base_currency_id from organizations where id = v_org);
  v_parent uuid;
  v_ar uuid; v_ap uuid; v_bank uuid; v_hold_in uuid; v_hold_out uuid;
  v_cust uuid; v_supp uuid;
  v_chq1 uuid; v_chq2 uuid; v_chq3 uuid;
  v_entry uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'A','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عميل',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم مورد',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'BANK','البنك',v_parent,true,'debit') returning id into v_bank;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'HIN','شيكات تحت التحصيل',v_parent,true,'debit') returning id into v_hold_in;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'HOUT','شيكات تحت الدفع',v_parent,true,'credit') returning id into v_hold_out;

  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل واحد',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد واحد',true,v_ap) returning id into v_supp;

  -- start the customer owing 1000, so AR carries a debit balance to reinstate against
  perform post_journal_entry(create_journal_entry(v_org, current_date - 10, 'فاتورة افتتاحية',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 1000, 'currency_id', v_base),
      jsonb_build_object('account_id', v_ap, 'credit', 1000, 'currency_id', v_base))));

  -- 1) incoming cheque 400 from the customer, received (reduces AR)
  v_entry := create_journal_entry(v_org, current_date, 'استلام شيك من عميل',
    jsonb_build_array(
      jsonb_build_object('account_id', v_hold_in, 'debit', 400, 'currency_id', v_base),
      jsonb_build_object('account_id', v_ar, 'credit', 400, 'currency_id', v_base)));
  perform post_journal_entry(v_entry);
  assert account_balance(v_ar) = 600, 'AR should drop to 600 after receiving the cheque';

  v_chq1 := create_cheque(v_org, 'incoming', 'CHQ-1', current_date + 30, 400, v_base, v_cust, v_hold_in);
  assert (select status from cheques where id = v_chq1) = 'in_hand', 'cheque should start in_hand';

  -- deposit then clear -> Dr bank / Cr holding
  perform set_cheque_deposited(v_chq1, v_bank);
  perform clear_cheque(v_chq1, current_date + 5);
  assert (select status from cheques where id = v_chq1) = 'cleared', 'cheque 1 should be cleared';
  assert account_balance(v_bank) = 400, 'bank should receive 400';
  assert account_balance(v_hold_in) = 0, 'holding(in) should net to 0 after clearing';

  -- terminal state is immutable
  begin
    perform set_cheque_deposited(v_chq1, v_bank);
    raise exception 'TEST FAIL: modified a cleared cheque';
  exception when sqlstate '23514' then null;
  end;

  -- 2) a second incoming cheque that bounces -> reinstates AR
  v_entry := create_journal_entry(v_org, current_date, 'استلام شيك آخر',
    jsonb_build_array(
      jsonb_build_object('account_id', v_hold_in, 'debit', 250, 'currency_id', v_base),
      jsonb_build_object('account_id', v_ar, 'credit', 250, 'currency_id', v_base)));
  perform post_journal_entry(v_entry);
  assert account_balance(v_ar) = 350, 'AR should drop to 350 after receiving the second cheque';
  v_chq2 := create_cheque(v_org, 'incoming', 'CHQ-2', current_date + 20, 250, v_base, v_cust, v_hold_in);
  perform set_cheque_deposited(v_chq2, v_bank);
  perform bounce_cheque(v_chq2, current_date + 3, 'رصيد غير كافٍ');
  assert (select status from cheques where id = v_chq2) = 'bounced', 'cheque 2 should be bounced';
  assert account_balance(v_ar) = 600, 'AR should be reinstated back to 600 after the bounce';
  assert account_balance(v_hold_in) = 0, 'holding(in) should net back to 0 after the bounce';

  -- 3) outgoing cheque to the supplier, cleared -> Dr holding / Cr bank
  v_entry := create_journal_entry(v_org, current_date, 'إصدار شيك لمورد',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ap, 'debit', 300, 'currency_id', v_base),
      jsonb_build_object('account_id', v_hold_out, 'credit', 300, 'currency_id', v_base)));
  perform post_journal_entry(v_entry);
  v_chq3 := create_cheque(v_org, 'outgoing', 'OUT-1', current_date + 15, 300, v_base, v_supp, v_hold_out);
  perform clear_cheque(v_chq3, current_date + 1, v_bank);   -- skip the deposit step entirely
  assert (select status from cheques where id = v_chq3) = 'cleared', 'outgoing cheque should be cleared';
  assert account_balance(v_bank) = 400 - 300, 'bank should net 100 (400 in - 300 out)';
  assert account_balance(v_hold_out) = 0, 'holding(out) should net to 0';

  -- an outgoing cheque cannot be endorsed
  begin
    perform endorse_cheque(v_chq3, current_date, v_ap, 'محاولة خاطئة');
    raise exception 'TEST FAIL: endorsed an outgoing cheque';
  exception when sqlstate '23514' then null;
  end;

  raise notice 'CHEQUES OK';
end $$;

rollback;
