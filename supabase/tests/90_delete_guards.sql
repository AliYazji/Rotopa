-- Draft documents can be deleted; posted/terminal ones cannot, across every
-- posted-document table.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('d1000000-0000-0000-0000-000000000001','del@test');
select set_config('request.jwt.claim.sub','d1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('DELORG','مؤسسة اختبار الحذف','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_base uuid := (select base_currency_id from organizations where id = v_org);
  v_parent uuid; v_a uuid; v_b uuid; v_cust uuid;
  v_wh uuid; v_item uuid;
  v_entry uuid; v_voucher uuid; v_cheque uuid; v_move uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'A','حساب أ',v_parent,true,'debit') returning id into v_a;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'B','حساب ب',v_parent,true,'credit') returning id into v_b;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_a) returning id into v_cust;
  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','رئيسي') returning id into v_wh;

  -- 1) a draft journal entry can be deleted; a posted one cannot
  v_entry := create_journal_entry(v_org, current_date, 'مسودة',
    jsonb_build_array(jsonb_build_object('account_id',v_a,'debit',10,'currency_id',v_base),
                       jsonb_build_object('account_id',v_b,'credit',10,'currency_id',v_base)));
  delete from journal_entries where id = v_entry;
  assert not exists (select 1 from journal_entries where id = v_entry), 'draft entry should be deletable';

  v_entry := create_journal_entry(v_org, current_date, 'سيُرحّل',
    jsonb_build_array(jsonb_build_object('account_id',v_a,'debit',10,'currency_id',v_base),
                       jsonb_build_object('account_id',v_b,'credit',10,'currency_id',v_base)));
  perform post_journal_entry(v_entry);
  begin
    delete from journal_entries where id = v_entry;
    raise exception 'TEST FAIL: deleted a posted journal entry';
  exception when sqlstate '23514' then null;
  end;

  -- 2) a draft voucher can be deleted; a posted one cannot
  v_voucher := create_voucher(v_org, 'receipt', current_date, 'مسودة', v_a, v_base,
    jsonb_build_array(jsonb_build_object('account_id', v_b, 'amount', 5)));
  delete from vouchers where id = v_voucher;
  assert not exists (select 1 from vouchers where id = v_voucher), 'draft voucher should be deletable';

  v_voucher := create_voucher(v_org, 'receipt', current_date, 'سيُرحّل', v_a, v_base,
    jsonb_build_array(jsonb_build_object('account_id', v_b, 'amount', 5)));
  perform post_voucher(v_voucher);
  begin
    delete from vouchers where id = v_voucher;
    raise exception 'TEST FAIL: deleted a posted voucher';
  exception when sqlstate '23514' then null;
  end;

  -- 3) an in-hand cheque can be deleted; a cleared one cannot
  v_cheque := create_cheque(v_org, 'incoming', 'DEL-1', current_date, 100, v_base, v_cust, v_a);
  delete from cheques where id = v_cheque;
  assert not exists (select 1 from cheques where id = v_cheque), 'in-hand cheque should be deletable';

  v_cheque := create_cheque(v_org, 'incoming', 'DEL-2', current_date, 100, v_base, v_cust, v_a);
  perform clear_cheque(v_cheque, current_date, v_b);
  begin
    delete from cheques where id = v_cheque;
    raise exception 'TEST FAIL: deleted a cleared cheque';
  exception when sqlstate '23514' then null;
  end;

  -- 4) a draft stock move can be deleted; a posted one cannot
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id)
  values (v_org, 'SKU', 'صنف', v_a, v_b) returning id into v_item;

  v_move := create_stock_move(v_org, 'opening', current_date, 'مسودة',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1, 'unit_cost', 1)));
  delete from stock_moves where id = v_move;
  assert not exists (select 1 from stock_moves where id = v_move), 'draft move should be deletable';

  v_move := create_stock_move(v_org, 'opening', current_date, 'سيُرحّل',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1, 'unit_cost', 1)));
  perform post_stock_move(v_move);
  begin
    delete from stock_moves where id = v_move;
    raise exception 'TEST FAIL: deleted a posted stock move';
  exception when sqlstate '23514' then null;
  end;

  raise notice 'DELETE GUARDS OK';
end $$;

rollback;
