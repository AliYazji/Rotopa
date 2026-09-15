-- Sales & purchase orders: draft->confirmed->cancelled lifecycle, partial
-- invoicing across multiple invoices, remaining-quantity enforcement,
-- confirmed-order immutability, delete guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f9000000-0000-0000-0009-000000000001','orders@test');
select set_config('request.jwt.claim.sub','f9000000-0000-0000-0009-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('ORDORG','مؤسسة اختبار الطلبات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_ap uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid; v_vat_out uuid; v_vat_in uuid;
  v_wh uuid; v_wh2 uuid; v_item uuid; v_cust uuid; v_supp uuid;
  v_so uuid; v_po uuid; v_inv1 uuid; v_inv2 uuid;
  v_row record;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATIN','ضريبة مدخلات',v_parent,true,'debit') returning id into v_vat_in;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into warehouses (org_id, code, name_ar) values (v_org,'W2','فرعي') returning id into v_wh2;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supp;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc, v_sales_acc, 25) returning id into v_item;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1000, 'unit_cost', 10))),
    v_equity);

  -- =========================================================================
  -- Sales order: 10 units ordered, delivered across two partial invoices
  -- =========================================================================
  v_so := create_sales_order(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 25)));
  assert (select status from sales_orders where id = v_so) = 'draft', 'new order should be draft';

  -- cannot invoice a draft order
  begin
    perform invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1)));
    raise exception 'TEST FAIL: invoiced a draft order';
  exception when sqlstate '23514' then null;
  end;

  perform confirm_sales_order(v_so);
  assert (select status from sales_orders where id = v_so) = 'confirmed', 'order should be confirmed';

  -- confirmed order's terms are locked
  begin
    perform confirm_sales_order(v_so);
    raise exception 'TEST FAIL: re-confirmed an already-confirmed order';
  exception when sqlstate '23514' then null;
  end;
  begin
    update sales_orders set warehouse_id = v_wh2 where id = v_so;
    raise exception 'TEST FAIL: changed a confirmed order''s warehouse';
  exception when sqlstate '23514' then null;
  end;
  begin
    insert into sales_order_lines (order_id, line_no, item_id, qty, unit_price) values (v_so, 99, v_item, 1, 25);
    raise exception 'TEST FAIL: added a line to a confirmed order';
  exception when sqlstate '23514' then null;
  end;

  -- first partial invoice: 6 of the 10 units
  v_inv1 := invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 6)));
  assert (select sales_order_id from sales_invoices where id = v_inv1) = v_so, 'invoice should record its originating order';
  assert (select unit_price from sales_invoice_lines where invoice_id = v_inv1) = 25, 'invoice line price should come from the order, not be re-entered';
  perform post_sales_invoice(v_inv1, p_output_vat_account_id := v_vat_out);

  -- cannot invoice more than what remains (10 - 6 = 4 left)
  begin
    perform invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5)));
    raise exception 'TEST FAIL: over-invoiced a sales order';
  exception when sqlstate '23514' then null;
  end;

  -- second partial invoice: exactly the remaining 4
  v_inv2 := invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 4)));
  perform post_sales_invoice(v_inv2, p_output_vat_account_id := v_vat_out);
  assert account_balance(v_ar) = round(10*25*1.16, 2), 'AR should reflect the full 10 units across both partial invoices';

  -- now fully invoiced: nothing left to invoice
  begin
    perform invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1)));
    raise exception 'TEST FAIL: invoiced beyond a fully-delivered order';
  exception when sqlstate '23514' then null;
  end;

  -- a confirmed order (even fully invoiced) can still be cancelled -- existing invoices are unaffected
  perform cancel_sales_order(v_so, 'اختبار');
  assert (select status from sales_orders where id = v_so) = 'cancelled', 'order should be cancellable even after full delivery';
  assert (select status from sales_invoices where id = v_inv1) = 'posted', 'existing invoices must be unaffected by cancelling their origin order';

  -- a cancelled order cannot be deleted, nor invoiced again
  begin
    delete from sales_orders where id = v_so;
    raise exception 'TEST FAIL: deleted a cancelled order';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1)));
    raise exception 'TEST FAIL: invoiced a cancelled order';
  exception when sqlstate '23514' then null;
  end;

  -- a fresh, untouched draft order can be deleted freely
  declare v_so2 uuid;
  begin
    v_so2 := create_sales_order(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 25)));
    delete from sales_orders where id = v_so2;
    assert not exists (select 1 from sales_orders where id = v_so2), 'a draft order should be deletable';
  end;

  -- =========================================================================
  -- Purchase order mirror: 20 units ordered, one partial invoice
  -- =========================================================================
  v_po := create_purchase_order(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 20, 'unit_price', 12)));
  perform confirm_purchase_order(v_po);

  v_inv1 := invoice_purchase_order(v_po, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 8)));
  assert (select purchase_order_id from purchase_invoices where id = v_inv1) = v_po, 'purchase invoice should record its originating order';
  perform post_purchase_invoice(v_inv1, v_vat_in);
  assert item_stock_on_hand(v_item, v_wh) = 1000 - 10 + 8, 'stock should reflect only the 8 units actually received so far';

  -- 15 more would exceed the remaining 12 (20 - 8)
  begin
    perform invoice_purchase_order(v_po, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 15)));
    raise exception 'TEST FAIL: over-invoiced a purchase order';
  exception when sqlstate '23514' then null;
  end;

  -- a dealer that is not a supplier cannot receive a purchase order
  begin
    perform create_purchase_order(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 12)));
    raise exception 'TEST FAIL: created a purchase order for a non-supplier';
  exception when sqlstate '23514' then null;
  end;

  raise notice 'SALES/PURCHASE ORDERS OK';
end $$;

rollback;
