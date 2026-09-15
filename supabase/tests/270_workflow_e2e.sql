-- End-to-end business workflow — one continuous story spanning nearly every
-- module built this project, instead of one module in isolation like every
-- other test file. Deliberately close to how a real org would actually use
-- the system day to day: team setup → chart of accounts → a supplier and a
-- customer → buy stock → sell some of it → get paid → a partial return →
-- close the period → confirm the audit trail and reporting all agree.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f6000000-0000-0000-0006-000000000001','owner@e2e.test'),
  ('f6000000-0000-0000-0006-000000000002','accountant@e2e.test');
select set_config('request.jwt.claim.sub','f6000000-0000-0000-0006-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('E2EORG','مؤسسة اختبار شامل','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_owner uuid := 'f6000000-0000-0000-0006-000000000001';
  v_acct_role uuid;
  v_parent uuid; v_ar_hdr uuid; v_ap_hdr uuid; v_ar uuid; v_ap uuid; v_cash uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid; v_vat_out uuid; v_vat_in uuid;
  v_cash_cat uuid; v_ar_cat uuid; v_ap_cat uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_supp uuid;
  v_po uuid; v_pinv uuid; v_so uuid; v_sinv uuid; v_voucher uuid; v_return uuid;
  v_period_id uuid;
  s record;
  ar_row record;
  audit_count_before int;
begin
  -- =========================================================================
  -- 1) team: owner invites an accountant who already has an account — joins
  --    immediately (the already-registered-email path from item 1's own test)
  -- =========================================================================
  select id into v_acct_role from roles where org_id = v_org and code = 'accountant';
  perform invite_member(v_org, 'accountant@e2e.test', v_acct_role, null);
  assert exists (select 1 from memberships where org_id = v_org and user_id = 'f6000000-0000-0000-0006-000000000002'),
    'the invited accountant should have a real membership immediately (already had an account)';

  -- =========================================================================
  -- 2) chart of accounts + categories (own-org, not ETL-seeded — same gap
  --    documented in the dashboard feature)
  -- =========================================================================
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance, sort_order) values
    (v_org, 'L100', 'النقد وشبة النقد', 'balance_sheet', 'asset', 'debit', 1),
    (v_org, 'L120', 'الذمم المدينة',    'balance_sheet', 'asset', 'debit', 2),
    (v_org, 'L300', 'ذمم دائنة',        'balance_sheet', 'liability', 'credit', 3);
  select id into v_cash_cat from account_categories where org_id = v_org and code = 'L100';
  select id into v_ar_cat   from account_categories where org_id = v_org and code = 'L120';
  select id into v_ap_cat   from account_categories where org_id = v_org and code = 'L300';

  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'CASH','صندوق',v_parent,true,'debit',v_cash_cat) returning id into v_cash;
  -- header (non-postable) accounts for create_dealer() to provision child
  -- accounts under — a dealer's OWN account is auto-created and inherits
  -- category_id/nature from this parent, it is never the parent itself
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'AR','ذمم العملاء',v_parent,false,'debit',v_ar_cat) returning id into v_ar_hdr;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'AP','ذمم الموردين',v_parent,false,'credit',v_ap_cat) returning id into v_ap_hdr;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATIN','ضريبة مدخلات',v_parent,true,'debit') returning id into v_vat_in;

  -- =========================================================================
  -- 3) a real supplier and customer via create_dealer() (auto-provisions
  --    their own ledger account, exactly like the real onboarding flow)
  -- =========================================================================
  v_supp := create_dealer(v_org, 'مورد الجملة', v_ap_hdr, p_is_supplier := true);
  v_cust := create_dealer(v_org, 'عميل التجزئة', v_ar_hdr, p_is_customer := true);
  select account_id into v_ar from dealers where id = v_cust;
  select account_id into v_ap from dealers where id = v_supp;

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'الرئيسي') returning id into v_wh;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU-E2E', 'صنف اختبار شامل', v_inv_acc, v_cogs_acc, v_sales_acc, 50) returning id into v_item;

  -- opening equity so the books have a real starting point
  perform post_journal_entry(create_journal_entry(v_org, current_date, 'رأس مال افتتاحي',
    jsonb_build_array(jsonb_build_object('account_id', v_cash, 'debit', 10000, 'currency_id', (select base_currency_id from organizations where id = v_org)),
                       jsonb_build_object('account_id', v_equity, 'credit', 10000, 'currency_id', (select base_currency_id from organizations where id = v_org)))));

  -- =========================================================================
  -- 4) purchasing: order → confirm → invoice → post (receives 100 units)
  -- =========================================================================
  v_po := create_purchase_order(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 100, 'unit_price', 20)));
  perform confirm_purchase_order(v_po);
  v_pinv := invoice_purchase_order(v_po, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 100)));
  perform post_purchase_invoice(v_pinv, v_vat_in);
  assert item_stock_on_hand(v_item, v_wh) = 100, 'should have 100 units on hand after the purchase posts';

  -- =========================================================================
  -- 5) selling: order → confirm → PARTIAL invoice → post (ships 30 of 60 ordered)
  -- =========================================================================
  v_so := create_sales_order(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 60, 'unit_price', 50)));
  perform confirm_sales_order(v_so);
  v_sinv := invoice_sales_order(v_so, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 30)));
  perform post_sales_invoice(v_sinv, p_output_vat_account_id := v_vat_out);
  assert item_stock_on_hand(v_item, v_wh) = 70, 'should have 70 units left after shipping 30 of the 100 purchased';
  assert account_balance(v_ar) = round(30*50*1.16, 2), 'AR should reflect exactly the shipped invoice, VAT included';

  -- =========================================================================
  -- 6) the customer pays part of what they owe
  -- =========================================================================
  v_voucher := create_voucher(v_org, 'receipt', current_date, 'دفعة من العميل', v_cash,
    (select base_currency_id from organizations where id = v_org),
    jsonb_build_array(jsonb_build_object('account_id', v_ar, 'amount', 1000, 'dealer_id', v_cust)));
  perform post_voucher(v_voucher);
  assert account_balance(v_ar) = round(30*50*1.16, 2) - 1000, 'AR should drop by exactly the receipt amount';

  -- =========================================================================
  -- 7) the customer returns 5 of the 30 units sold
  -- =========================================================================
  v_return := create_sales_return(v_org, v_sinv, jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5)));
  perform post_sales_return(v_return, p_output_vat_account_id := v_vat_out);
  assert item_stock_on_hand(v_item, v_wh) = 75, 'the 5 returned units should come back into stock (70 + 5)';

  -- =========================================================================
  -- 8) close today's fiscal period, confirm postings are then rejected,
  --    then reopen it (mandatory reason) to prove the whole workflow this
  --    session built (item 2) plugs correctly into a real business day)
  -- =========================================================================
  select id into v_period_id from fiscal_periods where org_id = v_org and current_date between start_date and end_date;
  -- close every period up to today's (chronological order, same as the
  -- dashboard test) since a fresh org's period-1-through-8 are still open
  declare v_pid uuid;
  begin
    for v_pid in select id from fiscal_periods where org_id = v_org and start_date <= (select start_date from fiscal_periods where id = v_period_id) order by start_date
    loop
      perform close_fiscal_period(v_pid);
    end loop;
  end;
  declare v_blocked_voucher uuid;
  begin
    v_blocked_voucher := create_voucher(v_org, 'receipt', current_date, 'محاولة بفترة مقفلة', v_cash,
      (select base_currency_id from organizations where id = v_org),
      jsonb_build_array(jsonb_build_object('account_id', v_ar, 'amount', 1, 'dealer_id', v_cust)));
    perform post_voucher(v_blocked_voucher);
    raise exception 'TEST FAIL: posted a voucher into a closed period';
  exception when sqlstate 'P0001' then null;
  end;
  perform reopen_fiscal_period(v_period_id, 'استكمال اختبار شامل بعد الإقفال التجريبي');
  assert (select status from fiscal_periods where id = v_period_id) = 'open', 'today''s period should be open again';

  -- =========================================================================
  -- 9) the whole story should be fully reflected in reporting + audit
  -- =========================================================================
  select * into s from dashboard_summary(v_org);
  assert s.cash_balance = 11000, 'cash should be the 10000 opening plus the 1000 receipt';
  assert s.ar_balance = round(25*50*1.16, 2) - 1000, 'AR should reflect 25 units still owed (30 sold - 5 returned) minus the payment';
  assert s.ap_balance = round(100*20*1.16, 2), 'AP should reflect the full posted purchase including VAT (never paid down in this story)';
  assert s.trial_balance_debit = s.trial_balance_credit, 'the whole multi-step story should still leave the ledger balanced';

  select * into ar_row from ar_aging_detail(v_org, current_date) where dealer_code is not null limit 1;
  assert ar_row.dealer_code is not null, 'AR aging should show the customer''s remaining open balance';

  assert (select count(*) from audit_log_query(v_org, p_table_name := 'sales_invoices')) >= 1, 'audit log should have captured the sales invoice lifecycle';
  assert (select count(*) from fiscal_period_closure_log(v_org)) >= 9, 'closure log should have one entry per period closed plus the reopen';

  raise notice 'WORKFLOW E2E OK';
end $$;

rollback;
