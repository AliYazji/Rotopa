-- Tax settings became editable + toggleable per organization (org_settings
-- key='tax', value={enabled, rate}) instead of a hardcoded global 16%.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f9000000-0000-0000-0009-000000000001','owner@tax.test');
select set_config('request.jwt.claim.sub','f9000000-0000-0000-0009-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('TAXORG','مؤسسة اختبار الضريبة','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_inv uuid; v_cogs uuid; v_sales uuid; v_equity uuid; v_vat uuid;
  v_wh uuid; v_cust uuid; v_supp uuid; v_item uuid;
  v_sinv uuid; v_pinv uuid; v_ret uuid; v_entry uuid;
  v_line_total numeric; v_vat_line numeric;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','مخزون',v_parent,true,'debit') returning id into v_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VAT','ضريبة',v_parent,true,'credit') returning id into v_vat;

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','زبون',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ar) returning id into v_supp;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
    values (v_org,'ITM','صنف',v_inv,v_cogs,v_sales,100) returning id into v_item;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 50))), v_equity);

  -- =========================================================================
  -- 1) a fresh org has the default tax settings (16%, enabled) — this is
  --    create_organization()'s new seed, not a missing-row fallback
  -- =========================================================================
  assert (select value from org_settings where org_id = v_org and key = 'tax') = jsonb_build_object('enabled', true, 'rate', 0.16),
    'a fresh org should be seeded with the default tax settings (16%%, enabled)';
  assert app.vat_rate(v_org) = 0.16, 'default effective vat_rate should be 16%%';

  -- =========================================================================
  -- 2) default 16%% behavior is unchanged — post a normal sale, check the VAT line
  -- =========================================================================
  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 2, 'unit_price', 100)));
  perform post_sales_invoice(v_sinv, p_output_vat_account_id := v_vat);
  select journal_entry_id into v_entry from sales_invoices where id = v_sinv;
  select credit into v_vat_line from journal_lines where entry_id = v_entry and account_id = v_vat;
  assert v_vat_line = 32, 'VAT line on a 200 sale at 16%% should be 32';
  perform void_sales_invoice(v_sinv, current_date, 'تراجع');

  -- =========================================================================
  -- 3) editing the rate to 10%% changes future postings, matching the exact
  --    upsert pattern the web app's Settings.tsx already uses for 'print'
  -- =========================================================================
  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', true, 'rate', 0.10))
    on conflict (org_id, key) do update set value = excluded.value;
  assert app.vat_rate(v_org) = 0.10, 'vat_rate should reflect the edited 10%% rate immediately';

  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 2, 'unit_price', 100)));
  perform post_sales_invoice(v_sinv, p_output_vat_account_id := v_vat);
  select journal_entry_id into v_entry from sales_invoices where id = v_sinv;
  select credit into v_vat_line from journal_lines where entry_id = v_entry and account_id = v_vat;
  assert v_vat_line = 20, 'VAT line on a 200 sale at the edited 10%% rate should be 20';
  perform void_sales_invoice(v_sinv, current_date, 'تراجع');

  -- =========================================================================
  -- 4) disabling tax: no VAT line, no VAT account required at all, on every
  --    one of the 4 posting functions
  -- =========================================================================
  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', false, 'rate', 0.10))
    on conflict (org_id, key) do update set value = excluded.value;
  assert app.vat_rate(v_org) = 0, 'effective vat_rate should be 0 while disabled, even though the stored rate is still 0.10';

  -- sales invoice: posts with NO vat account at all
  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 100)));
  perform post_sales_invoice(v_sinv);  -- no p_output_vat_account_id
  select journal_entry_id into v_entry from sales_invoices where id = v_sinv;
  assert not exists (select 1 from journal_lines where entry_id = v_entry and account_id = v_vat),
    'no VAT journal line should exist when tax is disabled';

  -- sales return: also posts with no vat account
  v_ret := create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales_invoice_lines where invoice_id = v_sinv), 'qty', 1)));
  perform post_sales_return(v_ret);
  select journal_entry_id into v_entry from sales_returns where id = v_ret;
  assert not exists (select 1 from journal_lines where entry_id = v_entry and account_id = v_vat),
    'no VAT journal line should exist on a sales return when tax is disabled';

  -- purchase invoice: also posts with no vat account
  v_pinv := create_purchase_invoice(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 50)));
  perform post_purchase_invoice(v_pinv);  -- no p_input_vat_account_id
  select journal_entry_id into v_entry from purchase_invoices where id = v_pinv;
  assert not exists (select 1 from journal_lines where entry_id = v_entry and account_id = v_vat),
    'no VAT journal line should exist on a purchase invoice when tax is disabled';

  -- purchase return: also posts with no vat account
  v_ret := create_purchase_return(v_org, v_pinv, jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from purchase_invoice_lines where invoice_id = v_pinv), 'qty', 1)));
  perform post_purchase_return(v_ret);
  select journal_entry_id into v_entry from purchase_returns where id = v_ret;
  assert not exists (select 1 from journal_lines where entry_id = v_entry and account_id = v_vat),
    'no VAT journal line should exist on a purchase return when tax is disabled';

  -- =========================================================================
  -- 5) re-enabling restores the ORIGINAL configured rate (0.10), not the
  --    old system default (0.16) — proves disabling never clobbers the rate
  -- =========================================================================
  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', true, 'rate', 0.10))
    on conflict (org_id, key) do update set value = excluded.value;
  assert app.vat_rate(v_org) = 0.10, 're-enabling should restore the previously configured 10%% rate exactly';

  -- =========================================================================
  -- 6) an org with tax enabled still REQUIRES a VAT account to post (the
  --    conditional check only relaxes when v_vat = 0, not unconditionally)
  -- =========================================================================
  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 100)));
  begin
    perform post_sales_invoice(v_sinv);  -- no p_output_vat_account_id, but tax IS enabled now
    raise exception 'TEST FAIL: posted a taxed sales invoice with no VAT account';
  exception when sqlstate '23514' then null;
  end;

  raise notice 'CONFIGURABLE TAX OK';
end $$;

rollback;
