-- VAT (module 17, flat-rate version): app.vat_rate() itself, and a
-- combined sales+purchase scenario showing output VAT (a liability) and
-- input VAT (an asset) land in separate accounts, netting to what's
-- actually owed to the tax authority. The line-by-line arithmetic is
-- already covered thoroughly in 80_sales.sql/110_purchases.sql (VAT is a
-- leg of those postings, not a separate document type) — this file is the
-- module-level sanity check, not a duplicate of that coverage.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('e2000000-0000-0000-0002-000000000001','vat@test');
select set_config('request.jwt.claim.sub','e2000000-0000-0000-0002-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('VATORG','مؤسسة اختبار الضريبة','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_ap uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid;
  v_vat_out uuid; v_vat_in uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_supp uuid;
  v_purchase uuid; v_sale uuid; v_move_open uuid;
begin
  assert app.vat_rate(v_org) = 0.16, 'the default rate should be 16%';

  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATIN','ضريبة مدخلات',v_parent,true,'debit') returning id into v_vat_in;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supp;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc, v_sales_acc, 25) returning id into v_item;

  -- opening stock so the later sale doesn't oversell (no VAT on opening balances)
  v_move_open := create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 10)));
  perform post_stock_move(v_move_open, v_equity);

  -- buy 100 @ 10 = 1000 subtotal, VAT 160 -> AP owed 1160
  v_purchase := create_purchase_invoice(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 100, 'unit_price', 10)));
  perform post_purchase_invoice(v_purchase, p_input_vat_account_id := v_vat_in);
  assert account_balance(v_vat_in) = 160, 'input VAT recoverable should be 160 (16% of 1000)';

  -- sell 20 @ 25 = 500 subtotal, VAT 80 -> AR owed 580
  v_sale := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 20, 'unit_price', 25)));
  perform post_sales_invoice(v_sale, p_output_vat_account_id := v_vat_out);
  assert account_balance(v_vat_out) = -80, 'output VAT payable should be 80 (16% of 500)';

  -- net VAT position: owes 80 in output, can reclaim 160 in input -> net refundable 80
  -- (debit-natured input 160, credit-natured output 80 -> net asset of 80)
  assert account_balance(v_vat_in) + account_balance(v_vat_out) = 80,
    'net VAT position should show 80 reclaimable (160 input - 80 output)';

  -- VAT never touches revenue, COGS, or inventory — those stay VAT-exclusive
  assert account_balance(v_sales_acc) = -500, 'revenue should be the VAT-exclusive 500, not 580';
  assert account_balance(v_inv_acc) = 500 + 1000 - 200, 'inventory should reflect only the VAT-exclusive cost (500 opening + 1000 purchase - 200 sold at cost 10), never the VAT amounts';

  raise notice 'VAT OK';
end $$;

rollback;
