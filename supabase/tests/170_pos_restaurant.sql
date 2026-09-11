-- POS/restaurant: table occupancy, open->add lines->settle (becomes a real
-- posted sales invoice), cancel frees the table, guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f4000000-0000-0000-0004-000000000001','pos-rest@test');
select set_config('request.jwt.claim.sub','f4000000-0000-0000-0004-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('POSRORG','مؤسسة اختبار المطعم','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_cash uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid; v_vat_out uuid;
  v_wh uuid; v_item uuid; v_cust uuid;
  v_outlet uuid; v_table1 uuid; v_table2 uuid;
  v_order1 uuid; v_order2 uuid; v_order3 uuid; v_line1 uuid; v_line2 uuid;
  v_invoice uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','صندوق المطعم',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','مبيعات المطعم',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','زبون',true,v_ar) returning id into v_cust;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'MEAL1', 'وجبة', v_inv_acc, v_cogs_acc, v_sales_acc, 40) returning id into v_item;

  -- stock it: 50 units @ cost 15
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 15))),
    v_equity);

  insert into outlets (org_id, code, name_ar) values (v_org, 'MAIN', 'المطعم الرئيسي') returning id into v_outlet;
  insert into pos_tables (org_id, outlet_id, table_no) values (v_org, v_outlet, 'T1') returning id into v_table1;
  insert into pos_tables (org_id, outlet_id, table_no) values (v_org, v_outlet, 'T2') returning id into v_table2;

  -- 1) open an order against table 1 -> table becomes occupied
  v_order1 := open_pos_order(v_org, v_outlet, v_wh, v_table1, 2, 'زبونان');
  assert (select status from pos_tables where id = v_table1) = 'occupied', 'table 1 should be occupied';
  assert (select status from pos_orders where id = v_order1) = 'open', 'order should start open';

  -- 2) cannot open a second order on the same (now-occupied) table
  begin
    perform open_pos_order(v_org, v_outlet, v_wh, v_table1);
    raise exception 'TEST FAIL: opened a second order on an occupied table';
  exception when sqlstate '23514' then null;
  end;

  -- 3) add two lines (2 meals @ 40, then 1 more added later) — default price from item.sales_price
  v_line1 := add_order_line(v_order1, v_item, 2);
  v_line2 := add_order_line(v_order1, v_item, 1, 35, 'سعر خاص');  -- explicit override price
  assert (select unit_price from pos_order_lines where id = v_line1) = 40, 'line without explicit price should default to item.sales_price';
  assert (select unit_price from pos_order_lines where id = v_line2) = 35, 'line with explicit price should keep it';

  -- 4) a line can be removed while the order is still open
  declare v_line3 uuid;
  begin
    v_line3 := add_order_line(v_order1, v_item, 1);
    delete from pos_order_lines where id = v_line3;
    assert not exists (select 1 from pos_order_lines where id = v_line3), 'line should be removable while open';
  end;

  -- 5) open + cancel a second order on the other table -> table frees up
  v_order2 := open_pos_order(v_org, v_outlet, v_wh, v_table2);
  perform cancel_pos_order(v_order2, 'الزبون غيّر رأيه');
  assert (select status from pos_orders where id = v_order2) = 'cancelled', 'order 2 should be cancelled';
  assert (select status from pos_tables where id = v_table2) = 'free', 'table 2 should be free again after cancel';

  -- 6) settle order 1 -> becomes a real posted sales invoice, table frees up
  --    2 x 40 + 1 x 35 = 115 subtotal, VAT 16% = 18.40, total 133.40
  v_invoice := settle_pos_order(v_order1, 'cash', v_cust, v_cash, v_sales_acc, v_vat_out);
  assert (select status from pos_orders where id = v_order1) = 'settled', 'order 1 should be settled';
  assert (select sales_invoice_id from pos_orders where id = v_order1) = v_invoice, 'order should record its resulting invoice';
  assert (select status from pos_tables where id = v_table1) = 'free', 'table 1 should be free after settling';
  assert (select status from sales_invoices where id = v_invoice) = 'posted', 'the resulting invoice should be posted';
  assert account_balance(v_sales_acc) = -115, 'sales should be credited the VAT-exclusive 115 (2x40 + 1x35)';
  assert round(account_balance(v_vat_out), 2) = -18.40, 'output VAT should be credited 16% of 115';
  assert account_balance(v_cash) = round(115 * 1.16, 2), 'the restaurant''s cash box should carry the VAT-inclusive total';
  assert account_balance(v_ar) = 0, 'the customer''s own AR account is untouched by a cash-designated settlement';
  assert account_balance(v_inv_acc) = 750 - 45, 'inventory should drop by the real cost (3 units x 15 = 45), from the 750 opening';

  -- 7) a settled order is frozen — no more lines, no cancelling, no field changes except notes
  begin
    perform add_order_line(v_order1, v_item, 1);
    raise exception 'TEST FAIL: added a line to a settled order';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform cancel_pos_order(v_order1, null);
    raise exception 'TEST FAIL: cancelled a settled order';
  exception when sqlstate '23514' then null;
  end;
  begin
    update pos_orders set guest_count = 99 where id = v_order1;
    raise exception 'TEST FAIL: changed guest_count on a settled order';
  exception when sqlstate '23514' then null;
  end;
  update pos_orders set notes = 'ملاحظة بعد التسوية' where id = v_order1;
  assert (select notes from pos_orders where id = v_order1) = 'ملاحظة بعد التسوية', 'cosmetic field should stay editable after settling';

  -- 8) a settled order cannot be deleted (extended shared delete-guard)
  begin
    delete from pos_orders where id = v_order1;
    raise exception 'TEST FAIL: deleted a settled order';
  exception when sqlstate '23514' then null;
  end;

  -- 9) a still-open order (never settled or cancelled) can be deleted freely
  v_order3 := open_pos_order(v_org, v_outlet, v_wh, null); -- takeaway, no table
  delete from pos_orders where id = v_order3;
  assert not exists (select 1 from pos_orders where id = v_order3), 'open order should be deletable';

  raise notice 'POS/RESTAURANT OK';
end $$;

rollback;
