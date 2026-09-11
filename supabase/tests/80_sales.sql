-- Sales invoice: 4-legged GL entry at the real computed cost, credit vs cash,
-- void restocks and reverses, guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('c1000000-0000-0000-0000-000000000001','sales@test');
select set_config('request.jwt.claim.sub','c1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('SALORG','مؤسسة اختبار المبيعات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_base uuid := (select base_currency_id from organizations where id = v_org);
  v_parent uuid; v_ar uuid; v_cash uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid;
  v_wh uuid; v_item uuid; v_cust uuid;
  v_inv1 uuid; v_inv2 uuid; v_entry uuid; v_move_open uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','الصندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc, v_sales_acc, 25) returning id into v_item;

  -- stock it: 100 units @ cost 10
  v_move_open := create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10)));
  perform post_stock_move(v_move_open, v_equity);

  -- 1) credit sale: 10 units @ 25 (price) — cost stays 10 (weighted average, one batch)
  v_inv1 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 25)));
  v_entry := post_sales_invoice(v_inv1);

  assert item_stock_on_hand(v_item, v_wh) = 90, 'stock should drop to 90 after the sale';
  assert account_balance(v_ar) = 250, 'AR should be debited 250 (10 x 25)';
  assert account_balance(v_sales_acc) = -250, 'sales should be credited 250';
  assert account_balance(v_cogs_acc) = 100, 'COGS should be debited 100 (10 x cost 10)';
  assert account_balance(v_inv_acc) = 1000 - 100, 'inventory should drop by the cost, 900';
  assert (select unit_cost from sales_invoice_lines where invoice_id = v_inv1) = 10, 'line cost should be the real moving average';

  -- entry must balance itself: 4 lines, dr=cr
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'sales entry must balance';

  -- 2) cash sale: 5 units @ 25 -> Dr cash, not AR
  v_inv2 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5, 'unit_price', 25)),
    p_payment_method := 'cash', p_cash_account_id := v_cash);
  perform post_sales_invoice(v_inv2);
  assert account_balance(v_cash) = 125, 'cash should be debited 125';
  assert account_balance(v_ar) = 250, 'AR should be unaffected by the cash sale';
  assert item_stock_on_hand(v_item, v_wh) = 85, 'stock should drop to 85';

  -- 3) cannot oversell beyond stock (inherited from the inventory engine)
  begin
    perform post_sales_invoice(create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 9999, 'unit_price', 25))));
    raise exception 'TEST FAIL: sold more than what is in stock';
  exception when sqlstate '23514' then null;
  end;

  -- 4) void the credit sale: restock 10 units and reverse the entry
  perform void_sales_invoice(v_inv1, current_date, 'اختبار الإلغاء');
  assert (select status from sales_invoices where id = v_inv1) = 'void', 'invoice should be void';
  assert item_stock_on_hand(v_item, v_wh) = 95, 'stock should return to 95 (85 + 10 restocked)';
  assert account_balance(v_ar) = 0, 'AR should net back to 0 for the voided invoice''s effect';
  assert account_balance(v_sales_acc) = -125, 'sales should net back to just the cash sale (125)';

  -- 5) posted invoice is immutable
  begin
    update sales_invoices set description = 'tampered' where id = v_inv2;
    raise exception 'TEST FAIL: edited a posted invoice';
  exception when sqlstate '23514' then null;
  end;

  -- 6) a dealer that is not a customer cannot receive a sales invoice
  declare v_supplier_only uuid; v_supplier_acc uuid;
  begin
    insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_supplier_acc;
    insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_supplier_acc) returning id into v_supplier_only;
    begin
      perform create_sales_invoice(v_org, current_date, v_supplier_only, v_wh,
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 25)));
      raise exception 'TEST FAIL: created a sales invoice for a non-customer';
    exception when sqlstate '23514' then null;
    end;
  end;

  raise notice 'SALES OK';
end $$;

rollback;
