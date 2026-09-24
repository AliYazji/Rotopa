-- Regression coverage for 20250911005200_purchase_return_cost_consistency.sql
-- and 20250911005400_purchase_variance_org_setting.sql.
--
-- Before this fix, a purchase return's inventory GL credit (from
-- purchase_return_lines.line_total, the ORIGINAL receiving cost) and the
-- actual reduction applied to item_warehouse_balances (qty * the item's
-- CURRENT moving average at the moment of the return, via the generic
-- weighted-average stock-move exit) silently diverged whenever the item's
-- average had moved since the original receipt — permanently splitting the
-- GL inventory account from the inventory sub-ledger. This test manufactures
-- exactly that drift, then proves: (a) the safe case reverses at the
-- original cost and keeps GL == sub-ledger exactly, (b) the unsafe case
-- (drift too large to absorb) is rejected until the organization's fixed
-- purchase-variance account (org_settings key='default_accounts', field
-- purchase_variance_account_id — never a per-call RPC argument a regular
-- clerk could pick) is configured, then succeeds cleanly, routing exactly
-- the unabsorbable difference to it — never to inventory, never to an
-- arbitrary account.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('fa000000-0000-0000-000a-000000000001','owner@purchreturncost.test');
select set_config('request.jwt.claim.sub','fa000000-0000-0000-000a-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PRCCORG','مؤسسة اختبار اتساق تكلفة مرتجع المشتريات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ap uuid; v_inv_acc uuid; v_cogs_acc uuid; v_variance uuid; v_equity uuid; v_vat_in uuid; v_vat_out uuid; v_sales uuid;
  v_wh uuid; v_supplier uuid; v_cust uuid;
  v_item uuid;
  v_p1 uuid; v_p1_line uuid; v_p2 uuid; v_sinv uuid;
  v_ret uuid;
  v_caught boolean; v_msg text;
  v_qty numeric; v_avg numeric;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'PPV','فروقات تقييم المشتريات',v_parent,true,'debit') returning id into v_variance;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATIN','ضريبة مدخلات',v_parent,true,'debit') returning id into v_vat_in;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supplier;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_equity) returning id into v_cust;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU', 'صنف', v_inv_acc, v_cogs_acc, v_sales, 999) returning id into v_item;

  -- =========================================================================
  -- manufacture a drifted average: buy 10 @ 100, sell 5 (exits at 100, the
  -- only batch), then buy 10 more @ 1 (a steep price drop) — leaves 15 units
  -- on hand at an average of 34, far from the original invoice's 100
  -- =========================================================================
  v_p1 := create_purchase_invoice(v_org, current_date, v_supplier, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 100)));
  perform post_purchase_invoice(v_p1, v_vat_in);
  v_p1_line := (select id from purchase_invoice_lines where invoice_id = v_p1);
  assert account_balance(v_inv_acc) = 1000, 'inventory should be debited 1000 for the 10@100 purchase';

  v_sinv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5, 'unit_price', 999)));
  perform post_sales_invoice(v_sinv, p_output_vat_account_id := v_vat_out);
  assert account_balance(v_inv_acc) = 500, 'inventory should drop to 500 after selling 5 units at the only average (100)';

  v_p2 := create_purchase_invoice(v_org, current_date, v_supplier, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 1)));
  perform post_purchase_invoice(v_p2, v_vat_in);
  assert account_balance(v_inv_acc) = 510, 'inventory should rise to 510 after the 10@1 purchase (500 + 10)';

  select qty, avg_cost into v_qty, v_avg from item_warehouse_balances where item_id = v_item and warehouse_id = v_wh;
  assert v_qty = 15 and v_avg = 34, 'sanity: 15 units on hand at an average of exactly 34 ((5*100+10*1)/15)';

  -- =========================================================================
  -- return all 10 units of the ORIGINAL 100-cost purchase. Reversing at the
  -- original cost (1000) would drive the remaining pool's value negative
  -- (15*34=510 total value on hand, less than the 1000 being reversed) — an
  -- explicit variance account is required, and the difference must go there,
  -- never silently absorbed by inventory and never dumped anywhere else
  -- =========================================================================
  v_ret := create_purchase_return(v_org, v_p1, jsonb_build_array(jsonb_build_object('invoice_line_id', v_p1_line, 'qty', 10)));

  -- no purchase_variance_account_id configured yet in org_settings -> rejected
  v_caught := false; v_msg := null;
  begin
    perform post_purchase_return(v_ret, v_vat_in);
  exception when sqlstate '23514' then
    v_caught := true;
    get stacked diagnostics v_msg = message_text;
  end;
  assert v_caught, 'posting this return without a configured variance account should be rejected — the drift cannot be safely absorbed into inventory';
  assert v_msg ilike '%variance%' or v_msg ilike '%فروقات%', 'the rejection should explain a variance account is needed, got: ' || coalesce(v_msg, '<null>');
  assert (select status from purchase_returns where id = v_ret) = 'draft', 'the rejected return should remain a draft';

  -- the RPC itself takes no variance-account argument at all — it is a
  -- fixed organization setting, not something a posting call can choose
  assert not exists (
    select 1 from pg_proc where proname = 'post_purchase_return' and pronargs = 3
  ), 'post_purchase_return must not have a 3-argument overload — the variance account is an org setting, not an RPC parameter';

  -- configure the org's fixed variance account (same org_settings row/key
  -- the web Settings page's default_accounts section writes)
  insert into org_settings (org_id, key, value)
  values (v_org, 'default_accounts', jsonb_build_object('purchase_variance_account_id', v_variance))
  on conflict (org_id, key) do update set value = org_settings.value || excluded.value;
  assert app.purchase_variance_account(v_org) = v_variance, 'the helper should now resolve the configured variance account';

  perform post_purchase_return(v_ret, v_vat_in);
  assert (select status from purchase_returns where id = v_ret) = 'posted', 'the return should post once the org has a configured variance account';

  select qty, avg_cost into v_qty, v_avg from item_warehouse_balances where item_id = v_item and warehouse_id = v_wh;
  assert v_qty = 5, 'the 10 returned units should leave 5 on hand (15 - 10)';
  assert v_avg = 0, 'the remaining balance''s average should floor at 0 once the drift exceeds what inventory could absorb';

  -- GL inventory dropped by only the SAFELY absorbed 510 (not the original-cost 1000)
  assert account_balance(v_inv_acc) = 0, 'inventory GL should drop from 510 to exactly 0 — the safely absorbable portion, matching the sub-ledger exactly';
  -- the unabsorbable remainder (1000 - 510 = 490) went to the variance account, nowhere else
  assert account_balance(v_variance) = -490, 'the variance account should carry exactly the 490 that inventory could not absorb';
  -- AP is still reduced by the full ORIGINAL cost (1000), regardless of inventory's valuation limits
  assert account_balance(v_ap) = -round((1000+10)*1.16,2) + round(1000*1.16,2),
    'AP should be credited back the full original-cost amount (1000) including its VAT, independent of the inventory-side cap';

  -- acceptance criterion: GL inventory value must equal the sub-ledger's own
  -- computed value (qty * avg_cost) for this item, exactly
  assert account_balance(v_inv_acc) = (select round(qty * avg_cost, 4) from item_warehouse_balances where item_id = v_item and warehouse_id = v_wh),
    'GL inventory value must equal the sub-ledger inventory value after the return';

  -- the journal entry itself still balances (debit AP == credit inventory + credit variance + credit VAT)
  declare s record; begin
    select sum(debit) as d, sum(credit) as c into s from journal_lines
    where entry_id = (select journal_entry_id from purchase_returns where id = v_ret);
    assert s.d = s.c, 'the purchase-return entry (inventory + variance split) must still balance exactly';
  end;

  raise notice 'PURCHASE RETURN COST CONSISTENCY OK';
end $$;

rollback;
