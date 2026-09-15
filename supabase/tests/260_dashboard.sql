-- Dashboard summary: cash/AR/AP balances from the real (categorize-accounts-
-- derived) category codes, this-month sales/purchases, trial-balance sanity
-- check, today's period/year status, and the operational worklist counts.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f5000000-0000-0000-0005-000000000001','owner@dash.test');
select set_config('request.jwt.claim.sub','f5000000-0000-0000-0005-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('DASHORG','مؤسسة اختبار اللوحة','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_cash uuid; v_ar uuid; v_ap uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid; v_vat_out uuid;
  v_cash_cat uuid; v_ar_cat uuid; v_ap_cat uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_supp uuid;
  v_inv uuid; v_so uuid;
  s record;
begin
  -- account_categories is per-org (unique(org_id,code)) and create_organization()
  -- does not seed it — only the ETL's categorize-accounts step does, for a
  -- migrated org. A from-scratch org (like this test's, and like any brand
  -- new signup through Onboarding) starts with none at all; tests build
  -- their own, same convention 150_financial_statements.sql already uses.
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance, sort_order) values
    (v_org, 'L100', 'النقد وشبة النقد', 'balance_sheet', 'asset', 'debit', 1),
    (v_org, 'L120', 'الذمم المدينة',    'balance_sheet', 'asset', 'debit', 2),
    (v_org, 'L300', 'ذمم دائنة',        'balance_sheet', 'liability', 'credit', 3);
  select id into v_cash_cat from account_categories where org_id = v_org and code = 'L100';
  select id into v_ar_cat   from account_categories where org_id = v_org and code = 'L120';
  select id into v_ap_cat   from account_categories where org_id = v_org and code = 'L300';

  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'CASH','صندوق',v_parent,true,'debit',v_cash_cat) returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit',v_ar_cat) returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'AP','ذمم موردين',v_parent,true,'credit',v_ap_cat) returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supp;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc, v_sales_acc, 20) returning id into v_item;

  -- opening: 1000 units into stock, funded by equity, and a manual cash injection
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1000, 'unit_cost', 10))),
    v_equity);
  perform post_journal_entry(create_journal_entry(v_org, current_date, 'رأس مال نقدي',
    jsonb_build_array(jsonb_build_object('account_id', v_cash, 'debit', 5000, 'currency_id', (select base_currency_id from organizations where id = v_org)),
                       jsonb_build_object('account_id', v_equity, 'credit', 5000, 'currency_id', (select base_currency_id from organizations where id = v_org)))));

  -- one posted credit sale this month (goes to AR)
  v_inv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5, 'unit_price', 20)));
  perform post_sales_invoice(v_inv, p_output_vat_account_id := v_vat_out);

  -- one draft sales invoice (should count toward the worklist, not the AR/sales totals)
  perform create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 20)));

  -- one draft purchase invoice
  perform create_purchase_invoice(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 8)));

  -- one confirmed sales order (open worklist item)
  v_so := create_sales_order(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 2, 'unit_price', 20)));
  perform confirm_sales_order(v_so);

  select * into s from dashboard_summary(v_org);

  assert s.cash_balance = 5000, 'cash_balance should reflect only the L100-categorized account';
  assert s.ar_balance = round(5*20*1.16, 2), 'ar_balance should reflect the posted credit sale including VAT';
  assert s.ap_balance = 0, 'ap_balance should be 0 — the purchase invoice is still a draft, not posted';
  assert s.sales_this_month = 100, 'sales_this_month should be the posted invoice''s net line total (5*20), excluding the draft';
  assert s.purchases_this_month = 0, 'purchases_this_month should be 0 — the only purchase invoice is a draft';
  assert s.trial_balance_debit = s.trial_balance_credit, 'a freshly built, fully posted ledger should be balanced';
  assert s.today_period_status = 'open', 'today''s period should be open on a freshly created org';
  assert s.fiscal_year_status = 'open', 'the fiscal year should be open on a freshly created org';
  assert s.draft_sales_invoices = 1, 'exactly one draft sales invoice';
  assert s.draft_purchase_invoices = 1, 'exactly one draft purchase invoice';
  assert s.open_sales_orders = 1, 'exactly one confirmed sales order';
  assert s.open_purchase_orders = 0, 'no purchase orders created';
  assert s.pending_invitations = 0, 'no invitations created';

  -- close every period up to and including today's (closing must happen in
  -- chronological order per item 2's guard — today's period is rarely #1)
  declare v_pid uuid;
  begin
    for v_pid in
      select id from fiscal_periods
      where org_id = v_org and start_date <= (
        select start_date from fiscal_periods where org_id = v_org and current_date between start_date and end_date
      )
      order by start_date
    loop
      perform close_fiscal_period(v_pid);
    end loop;
  end;
  select * into s from dashboard_summary(v_org);
  assert s.today_period_status = 'closed', 'dashboard should reflect a just-closed period immediately';

  raise notice 'DASHBOARD OK';
end $$;

rollback;
