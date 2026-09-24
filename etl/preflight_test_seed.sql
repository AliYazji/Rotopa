\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email) values ('e0000000-0000-0000-0000-000000000001','preflight@test.local');
select set_config('request.jwt.claim.sub','e0000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PFTEST','مؤسسة اختبار الفحص المسبق','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_ap uuid; v_inv uuid; v_cogs uuid; v_sales uuid; v_eq uuid; v_vat_out uuid;
  v_wh uuid; v_cust uuid; v_item1 uuid; v_item2 uuid;
  v_inv1 uuid; v_inv2 uuid; v_inv3 uuid; v_line1a uuid; v_line1b uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','مخزون',v_parent,true,'debit') returning id into v_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','مبيعات',v_parent,true,'credit') returning id into v_sales;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','ملكية',v_parent,true,'credit') returning id into v_eq;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','رئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
    values (v_org, 'I1', 'صنف1', v_inv, v_cogs, v_sales, 50) returning id into v_item1;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
    values (v_org, 'I2', 'صنف2', v_inv, v_cogs, v_sales, 30) returning id into v_item2;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد', jsonb_build_array(
    jsonb_build_object('item_id', v_item1, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10),
    jsonb_build_object('item_id', v_item2, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 5)
  )), v_eq);

  -- 1) CONFIRMED: a normal taxed invoice — real VAT line exists
  v_inv1 := create_sales_invoice(v_org, current_date, v_cust, v_wh, jsonb_build_array(jsonb_build_object('item_id', v_item1, 'qty', 10, 'unit_price', 50)));
  perform post_sales_invoice(v_inv1, p_output_vat_account_id := v_vat_out);

  -- 2) CONFIRMED_ZERO: tax disabled for this one -> no VAT line, but entry
  --    total reconciles exactly to "no tax" (line_total == control total)
  update org_settings set value = jsonb_build_object('enabled', false, 'rate', 0.16) where org_id = v_org and key = 'tax';
  v_inv2 := create_sales_invoice(v_org, current_date, v_cust, v_wh, jsonb_build_array(jsonb_build_object('item_id', v_item1, 'qty', 5, 'unit_price', 50)));
  perform post_sales_invoice(v_inv2, p_output_vat_account_id := v_vat_out);
  update org_settings set value = jsonb_build_object('enabled', true, 'rate', 0.16) where org_id = v_org and key = 'tax';

  -- 3) UNRESOLVED (synthetic legacy-data simulation): an invoice whose VAT
  --    was posted under a DIFFERENT historical description than every
  --    version of post_sales_invoice() has ever used — simulating data that
  --    predates this codebase's own migration history (e.g. migrated
  --    directly from the legacy system). The preflight tool must NOT
  --    silently call this "confirmed zero" — it must flag it.
  v_inv3 := create_sales_invoice(v_org, current_date, v_cust, v_wh, jsonb_build_array(jsonb_build_object('item_id', v_item1, 'qty', 4, 'unit_price', 50)));
  perform post_sales_invoice(v_inv3, p_output_vat_account_id := v_vat_out);
  create temp table pf_ids (k text primary key, v uuid);
  insert into pf_ids values ('inv3', v_inv3);

  -- 4) AMBIGUOUS return-link candidate: same item on two lines of one invoice
  declare v_inv4 uuid; begin
    v_inv4 := create_sales_invoice(v_org, current_date, v_cust, v_wh, jsonb_build_array(
      jsonb_build_object('item_id', v_item2, 'qty', 3, 'unit_price', 30),
      jsonb_build_object('item_id', v_item2, 'qty', 2, 'unit_price', 30)
    ));
    perform post_sales_invoice(v_inv4, p_output_vat_account_id := v_vat_out);
    declare v_ret uuid; begin
      v_ret := create_sales_return(v_org, v_inv4, jsonb_build_array(jsonb_build_object('item_id', v_item2, 'qty', 1)));
    end;
  end;

  insert into pf_ids values ('item2', v_item2), ('wh', v_wh);

  raise notice 'PREFLIGHT TEST SEED OK — inv1=% inv2=% inv3=%', v_inv1, v_inv2, v_inv3;
end $$;

reset role;
alter table journal_lines disable trigger journal_line_validate;
update journal_lines set description = 'ضريبة (نظام قديم)'
  where entry_id = (select journal_entry_id from sales_invoices where id = (select v from pf_ids where k = 'inv3'))
    and description = 'ضريبة قيمة مضافة على المبيعات';
alter table journal_lines enable trigger journal_line_validate;

-- 5) inventory red flag: force a negative average cost directly (data
--    corruption scenario a preflight run should catch, not something the
--    normal RPC surface could ever produce on its own)
update item_warehouse_balances set avg_cost = -1
  where item_id = (select v from pf_ids where k = 'item2') and warehouse_id = (select v from pf_ids where k = 'wh');

commit;
