-- Sales & purchase returns: partial, invoice-referenced, restock/de-stock at
-- the right cost, VAT legs mirrored, over-return rejected, void un-reverses.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f5000000-0000-0000-0005-000000000001','returns@test');
select set_config('request.jwt.claim.sub','f5000000-0000-0000-0005-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('RETORG','مؤسسة اختبار المرتجعات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_ap uuid; v_cash uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid;
  v_equity uuid; v_vat_out uuid; v_vat_in uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_supplier uuid;
  v_sinv uuid; v_pinv uuid; v_sret uuid; v_pret uuid; v_sret_void uuid; v_pret_void uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','الصندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATIN','ضريبة مدخلات',v_parent,true,'debit') returning id into v_vat_in;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supplier;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc, v_sales_acc, 25) returning id into v_item;

  -- stock it: 100 units @ cost 10
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10))),
    v_equity);

  -- =========================================================================
  -- Sales return
  -- =========================================================================
  -- credit sale: 10 units @ 25 (subtotal 250, VAT 40, total 290) — cost 10/unit
  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 25)));
  perform post_sales_invoice(v_sinv, p_output_vat_account_id := v_vat_out);
  assert item_stock_on_hand(v_item, v_wh) = 90, 'stock should drop to 90 after the sale';

  -- 1) cannot return against a draft/unposted invoice
  begin
    perform create_sales_return(v_org, create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 25))),
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1)));
    raise exception 'TEST FAIL: returned against a draft invoice';
  exception when sqlstate '23514' then null;
  end;

  -- 2) return 4 of the 10 units, credit (reduces AR) — price/cost pulled from the original line, not client-supplied
  v_sret := create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 4)));
  assert (select unit_price from sales_return_lines where return_id = v_sret) = 25, 'return line price should come from the original invoice line';
  assert (select unit_cost  from sales_return_lines where return_id = v_sret) = 10, 'return line cost should come from the original invoice line';

  perform post_sales_return(v_sret, p_output_vat_account_id := v_vat_out);
  assert (select status from sales_returns where id = v_sret) = 'posted', 'return should be posted';
  assert item_stock_on_hand(v_item, v_wh) = 94, 'stock should go back up by the 4 returned units (90 + 4)';
  assert account_balance(v_ar) = 290 - round(4*25*1.16,2), 'AR should be credited back 4 units'' worth including VAT';
  assert account_balance(v_sales_acc) = -(250 - 100), 'sales should net down by the 100 (4x25) returned';
  assert account_balance(v_vat_out) = -(40 - 16), 'output VAT should net down by 16 (16% of 100)';
  assert account_balance(v_cogs_acc) = 100 - 40, 'COGS should net down by 40 (4x10) restocked';
  assert account_balance(v_inv_acc) = 1000 - 100 + 40, 'inventory should go back up by the 40 (4x10) restocked cost';

  -- 3) cannot over-return: only 6 units remain returnable (10 - 4 already returned)
  begin
    perform create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 7)));
    raise exception 'TEST FAIL: over-returned a sales invoice line';
  exception when sqlstate '23514' then null;
  end;

  -- 4) void the return: de-stock the 4 units again and reverse its entry
  v_sret_void := void_sales_return(v_sret, current_date, 'اختبار إلغاء المرتجع');
  assert (select status from sales_returns where id = v_sret) = 'void', 'return should be void';
  assert item_stock_on_hand(v_item, v_wh) = 90, 'stock should drop back to 90 after voiding the return';
  assert account_balance(v_ar) = 290, 'AR should be back to the full original invoice amount';
  assert account_balance(v_sales_acc) = -250, 'sales should be back to the full original 250';
  assert account_balance(v_vat_out) = -40, 'output VAT should be back to the full original 40';

  -- 5) a voided return frees up the quantity again — now returnable in full
  v_sret := create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10)));
  perform post_sales_return(v_sret, p_output_vat_account_id := v_vat_out);
  assert account_balance(v_ar) = 0, 'AR should net to zero once the whole invoice has been returned';
  assert item_stock_on_hand(v_item, v_wh) = 100, 'all 10 units should be back in stock';

  -- 6) posted return is immutable; only void_sales_return can touch it
  begin
    update sales_returns set description = 'tampered' where id = v_sret;
    raise exception 'TEST FAIL: edited a posted return';
  exception when sqlstate '23514' then null;
  end;

  -- =========================================================================
  -- Purchase return
  -- =========================================================================
  -- credit purchase: 20 units @ 12 (subtotal 240, VAT 38.40, total 278.40)
  v_pinv := create_purchase_invoice(v_org, current_date, v_supplier, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 20, 'unit_price', 12)));
  perform post_purchase_invoice(v_pinv, v_vat_in);
  assert item_stock_on_hand(v_item, v_wh) = 120, 'stock should rise to 120 (100 + 20 purchased)';

  -- 7) cash purchase return: 5 units back to the supplier, refunded to cash
  v_pret := create_purchase_return(v_org, v_pinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5)),
    p_payment_method := 'cash', p_cash_account_id := v_cash);
  perform post_purchase_return(v_pret, v_vat_in);
  assert (select status from purchase_returns where id = v_pret) = 'posted', 'purchase return should be posted';
  assert item_stock_on_hand(v_item, v_wh) = 115, 'stock should drop by the 5 returned units (120 - 5)';
  assert account_balance(v_cash) = round(5*12*1.16,2), 'cash should be debited (refund received) for 5 units incl. VAT';
  assert account_balance(v_ap) = -round(20*12*1.16,2), 'AP is untouched by a cash-designated return';
  assert account_balance(v_inv_acc) = 1000 + round(20*12,2) - round(5*12,2), 'inventory should drop by 60 (5x12, the original invoice price) from the purchase-return';
  assert account_balance(v_vat_in) = round(20*12*0.16,2) - round(5*12*0.16,2), 'input VAT should net down by the returned portion''s VAT';

  -- 8) cannot over-return a purchase line either
  begin
    perform create_purchase_return(v_org, v_pinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 16)));
    raise exception 'TEST FAIL: over-returned a purchase invoice line';
  exception when sqlstate '23514' then null;
  end;

  -- 9) void the purchase return: goods come back in, entry reverses
  v_pret_void := void_purchase_return(v_pret, current_date, 'اختبار إلغاء مرتجع المشتريات');
  assert (select status from purchase_returns where id = v_pret) = 'void', 'purchase return should be void';
  assert item_stock_on_hand(v_item, v_wh) = 120, 'stock should go back up to 120 after voiding the return';
  assert account_balance(v_ap) = -round(20*12*1.16,2), 'AP should be unaffected throughout (this return was cash)';

  -- 10) posting without the relevant VAT account is rejected clearly, for both directions
  begin
    perform post_sales_return(create_sales_return(v_org, v_sinv, '[]'::jsonb));
    raise exception 'TEST FAIL: posted a sales return with no lines';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform post_purchase_return(create_purchase_return(v_org, v_pinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1))));
    raise exception 'TEST FAIL: posted a purchase return with no input VAT account';
  exception when sqlstate '23514' then null;
  end;

  raise notice 'RETURNS OK';
end $$;

rollback;
