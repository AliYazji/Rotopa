-- Regression coverage for 20250911004800_tax_snapshot.sql.
--
-- Before this fix, no tax rate/amount was ever stored on an invoice or its
-- lines — every screen (and post_sales_return()/post_purchase_return())
-- re-derived "how much tax was charged" from the org's CURRENT tax
-- setting via app.vat_rate(org_id). Changing the org's rate after an
-- invoice was posted would retroactively change what that old invoice
-- appears to have charged. This test posts an invoice at one rate, then
-- changes the org's rate, and proves the already-posted invoice's stored
-- tax_rate/tax_amount are completely unaffected, while a NEW invoice
-- posted after the change correctly gets the new rate.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-0014-000000000001','owner@taxsnap.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-0014-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('TAXSNAPORG','مؤسسة اختبار لقطة الضريبة')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_rev uuid; v_inv_acc uuid; v_cogs uuid; v_vat_out uuid; v_cust_ctrl uuid;
  v_wh uuid; v_item uuid; v_cust uuid;
  v_invoice1 uuid; v_invoice2 uuid;
  r record;
begin
  select id into v_cash    from accounts where org_id = v_org and code = '11101';
  select id into v_rev     from accounts where org_id = v_org and code = '61101';
  select id into v_inv_acc from accounts where org_id = v_org and code = '11601';
  select id into v_cogs    from accounts where org_id = v_org and code = '51101';
  select id into v_vat_out from accounts where org_id = v_org and code = '31401';
  select id into v_cust_ctrl from accounts where org_id = v_org and code = '11501';

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'المستودع الرئيسي') returning id into v_wh;
  v_cust := create_dealer(v_org, 'عميل اختبار', v_cust_ctrl, p_is_customer := true);
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'TAXSKU', 'صنف اختبار', v_inv_acc, v_cogs, v_rev, 100)
  returning id into v_item;
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 20))),
    (select id from accounts where org_id = v_org and code = '41001'));

  -- org default tax is enabled at 16% (from create_organization's own seed)
  assert app.vat_rate(v_org) = 0.16, 'sanity: this org should start at the default 16% rate';

  -- =========================================================================
  -- 1) post an invoice at 16% — 1000 subtotal, 160 VAT
  -- =========================================================================
  v_invoice1 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 100)));
  perform post_sales_invoice(v_invoice1, p_output_vat_account_id := v_vat_out);

  select tax_rate, tax_amount into r from sales_invoices where id = v_invoice1;
  assert r.tax_rate = 0.16, 'invoice 1 should have frozen tax_rate=0.16, got ' || r.tax_rate;
  assert r.tax_amount = 160, 'invoice 1 should have frozen tax_amount=160, got ' || r.tax_amount;
  assert (select tax_rate from sales_invoice_lines where invoice_id = v_invoice1) = 0.16,
    'invoice 1''s line should also have the frozen tax_rate=0.16';

  -- =========================================================================
  -- 2) change the org's tax rate — the already-posted invoice must be
  --    completely unaffected
  -- =========================================================================
  update org_settings set value = jsonb_build_object('enabled', true, 'rate', 0.10)
  where org_id = v_org and key = 'tax';
  assert app.vat_rate(v_org) = 0.10, 'sanity: the org rate should now read 10%';

  select tax_rate, tax_amount into r from sales_invoices where id = v_invoice1;
  assert r.tax_rate = 0.16, 'invoice 1''s stored tax_rate must stay 0.16 after the org rate changed, got ' || r.tax_rate;
  assert r.tax_amount = 160, 'invoice 1''s stored tax_amount must stay 160 after the org rate changed, got ' || r.tax_amount;

  -- =========================================================================
  -- 3) a NEW invoice posted after the change correctly gets the NEW rate —
  --    proves this isn't just a frozen default, each posting captures its
  --    own moment's real rate
  -- =========================================================================
  v_invoice2 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 100)));
  perform post_sales_invoice(v_invoice2, p_output_vat_account_id := v_vat_out);

  select tax_rate, tax_amount into r from sales_invoices where id = v_invoice2;
  assert r.tax_rate = 0.10, 'invoice 2 (posted after the rate change) should have tax_rate=0.10, got ' || r.tax_rate;
  assert r.tax_amount = 100, 'invoice 2 should have tax_amount=100 (1000*0.10), got ' || r.tax_amount;

  -- invoice 1 is STILL unaffected after invoice 2 posted too
  select tax_rate, tax_amount into r from sales_invoices where id = v_invoice1;
  assert r.tax_rate = 0.16 and r.tax_amount = 160, 'invoice 1 must remain frozen even after a later invoice posts at a different rate';

  raise notice 'TAX SNAPSHOT OK';
end $$;

rollback;
