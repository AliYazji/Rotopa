-- Multi-UOM invoicing: sell/buy in a non-base unit (كرتون = 12 قطعة),
-- correct base-unit stock movement, correct per-base-unit cost in COGS/
-- inventory (not the entered-unit price), returns inherit the sale's unit,
-- voids restock/destock the right base quantity.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f7000000-0000-0000-0007-000000000001','uom@test');
select set_config('request.jwt.claim.sub','f7000000-0000-0000-0007-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('UOMORG','مؤسسة اختبار الوحدات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_ap uuid; v_cash uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid;
  v_vat_out uuid; v_vat_in uuid;
  v_wh uuid; v_item uuid; v_carton uuid; v_cust uuid; v_supp uuid;
  v_pinv uuid; v_sinv uuid; v_sret uuid; v_pret uuid; v_sinv_line uuid;
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
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supp;

  insert into items (org_id, code, name_ar, base_unit_name, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', 'قطعة', v_inv_acc, v_cogs_acc, v_sales_acc, 15) returning id into v_item;
  insert into item_units (item_id, unit_name, conversion_factor) values (v_item, 'كرتون', 12) returning id into v_carton;

  -- =========================================================================
  -- Purchase 5 كرتون @ 120/كرتون (= 10/قطعة) -> 60 قطعة land in stock @ avg 10
  -- =========================================================================
  v_pinv := create_purchase_invoice(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5, 'unit_price', 120, 'unit_id', v_carton)));
  assert (select unit_id from purchase_invoice_lines where invoice_id = v_pinv) = v_carton, 'line should record the chosen unit';
  assert (select base_qty from purchase_invoice_lines where invoice_id = v_pinv) = 60, 'base_qty should be 5 x 12 = 60';
  perform post_purchase_invoice(v_pinv, v_vat_in);

  assert item_stock_on_hand(v_item, v_wh) = 60, 'stock should be 60 pieces (5 cartons x 12)';
  assert (select avg_cost from item_warehouse_balances where item_id = v_item and warehouse_id = v_wh) = 10, 'avg cost should be 10 per piece (120/12), not 120';
  assert account_balance(v_inv_acc) = 600, 'inventory account should carry the full commercial value 5x120=600 regardless of unit';
  assert account_balance(v_vat_in) = round(600*0.16,2), 'input VAT should be 16% of the commercial value';

  -- stock move itself should show the real unit, for a correct audit trail
  assert (select sml.unit_id from stock_move_lines sml where sml.move_id = (select stock_move_id from purchase_invoices where id = v_pinv)) = v_carton,
    'the stock move should preserve the real transacted unit (كرتون), not silently convert to base for display';

  -- =========================================================================
  -- Sell 2 كرتون @ 180/كرتون -> 24 قطعة leave stock, COGS = 24 x 10 = 240 (NOT 2 x 10 = 20)
  -- =========================================================================
  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 2, 'unit_price', 180, 'unit_id', v_carton)));
  perform post_sales_invoice(v_sinv, p_output_vat_account_id := v_vat_out);

  assert item_stock_on_hand(v_item, v_wh) = 36, 'stock should drop to 36 (60 - 24)';
  assert account_balance(v_sales_acc) = -360, 'revenue should be 2 x 180 = 360, the entered-unit price, VAT-exclusive';
  assert account_balance(v_cogs_acc) = 240, 'COGS must be base_qty(24) x unit_cost(10) = 240 -- using entered qty(2) x cost would wrongly give 20';
  assert account_balance(v_inv_acc) = 600 - 240, 'inventory should drop by the same 240, matching COGS';
  assert (select unit_cost from sales_invoice_lines where invoice_id = v_sinv) = 10, 'line unit_cost pulled back from the stock move is per base unit (10), not per carton';

  -- =========================================================================
  -- Return 1 of the 2 كرتون sold -> inherits the carton unit automatically
  -- =========================================================================
  v_sinv_line := (select id from sales_invoice_lines where invoice_id = v_sinv);
  v_sret := create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('invoice_line_id', v_sinv_line, 'qty', 1)));
  assert (select unit_id from sales_return_lines where return_id = v_sret) = v_carton, 'return should inherit the original sale''s unit automatically';
  assert (select base_qty from sales_return_lines where return_id = v_sret) = 12, 'returning 1 كرتون should be 12 قطعة at the base level';

  -- over-return: only 1 كرتون remains returnable (2 sold - 1 already being returned isn't posted yet, so this checks the qty=2 attempt against the ORIGINAL 2 sold)
  begin
    perform create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('invoice_line_id', v_sinv_line, 'qty', 3)));
    raise exception 'TEST FAIL: over-returned in carton units';
  exception when sqlstate '23514' then null;
  end;

  perform post_sales_return(v_sret, p_output_vat_account_id := v_vat_out);
  assert item_stock_on_hand(v_item, v_wh) = 48, 'stock should go back up by 12 (36 + 12)';
  assert account_balance(v_cogs_acc) = 240 - 120, 'COGS should net down by base_qty(12) x cost(10) = 120';
  assert account_balance(v_sales_acc) = -360 + 180, 'revenue should net down by the returned carton''s own price, 180';

  -- =========================================================================
  -- Void the sales return: destock 12 pieces again
  -- =========================================================================
  perform void_sales_return(v_sret, current_date, 'اختبار');
  assert item_stock_on_hand(v_item, v_wh) = 36, 'stock should drop back to 36 after voiding the return';

  -- =========================================================================
  -- Purchase return: 1 of the 5 كرتون purchased goes back
  -- =========================================================================
  v_pret := create_purchase_return(v_org, v_pinv, jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from purchase_invoice_lines where invoice_id = v_pinv), 'qty', 1)));
  assert (select base_qty from purchase_return_lines where return_id = v_pret) = 12, 'purchase return base_qty should be 12 (1 carton)';
  perform post_purchase_return(v_pret, v_vat_in);
  assert item_stock_on_hand(v_item, v_wh) = 24, 'stock should drop by 12 (36 - 12)';
  assert account_balance(v_inv_acc) = 600 - 240 - 120, 'inventory should drop by the returned carton''s commercial value, 120';

  -- void the purchase return: 12 pieces land back at cost 120/12=10/piece
  perform void_purchase_return(v_pret, current_date, 'اختبار');
  assert item_stock_on_hand(v_item, v_wh) = 36, 'stock should go back up to 36 after voiding the purchase return';
  assert (select avg_cost from item_warehouse_balances where item_id = v_item and warehouse_id = v_wh) = 10, 'avg cost should still read 10/piece, not 120/piece, after the round trip';

  -- =========================================================================
  -- Void the original sale entirely: restock the base quantity that left (24)
  -- =========================================================================
  perform void_sales_invoice(v_sinv, current_date, 'اختبار');
  assert item_stock_on_hand(v_item, v_wh) = 60, 'stock should be fully back to 60 (36 + 24) after voiding the sale';

  -- =========================================================================
  -- Plain base-unit line (no unit_id) still works exactly as before
  -- =========================================================================
  declare v_plain uuid;
  begin
    v_plain := create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5, 'unit_price', 15)));
    assert (select unit_id from sales_invoice_lines where invoice_id = v_plain) is null, 'no unit given should mean base unit (null)';
    assert (select base_qty from sales_invoice_lines where invoice_id = v_plain) = 5, 'base_qty should equal qty for a base-unit line';
    perform post_sales_invoice(v_plain, p_output_vat_account_id := v_vat_out);
    assert item_stock_on_hand(v_item, v_wh) = 55, 'stock should drop by exactly 5 pieces for a base-unit sale';
  end;

  raise notice 'MULTI-UOM INVOICING OK';
end $$;

rollback;
