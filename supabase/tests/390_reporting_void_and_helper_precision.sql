-- Regression coverage for 20250911004500_reporting_void_and_helper_precision.sql.
--
-- Three independent root causes, three blocks:
--   1) void_journal_entry() never deletes the original entry — it flips it
--      to status='void' and inserts a separately-dated 'posted' reversal.
--      20250911004400 filtered every report on status='posted' only,
--      which silently dropped the (still historically real) original and
--      changed already-published historical reports retroactively the
--      moment a later void happened.
--   2) account_balance()/chart_of_accounts_balances() were never touched
--      by the earlier reporting-precision fixes and still filtered by
--      fiscal_periods.start_date <= p_as_of (period-level, not entry-
--      level) — the same day-precision bug fixed for the main reports.
--   3) account_ledger() also filtered status='posted' only, so a voided
--      entry's own line vanished from the ledger while its reversal
--      stayed — breaking the narrative and the running balance.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-0011-000000000001','owner@voidprecision.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-0011-000000000001', true);
set local role authenticated;

-- ============================================================================
-- BLOCK 1 — void/reversal must not disappear from, or retroactively
-- change, historical reports. entry_date (not current status) decides
-- when an entry's effect is in scope.
-- ============================================================================
do $$
declare
  v_org uuid := create_organization('VOIDORG', 'مؤسسة اختبار الإلغاء');
  v_year int := extract(year from now())::int;
  v_date_jan10 date := make_date(v_year, 1, 10);
  v_date_jan31 date := make_date(v_year, 1, 31);
  v_date_feb10 date := make_date(v_year, 2, 10);
  v_date_feb28 date := make_date(v_year, 2, 28);
  v_cash uuid; v_rev uuid;
  v_cur uuid;
  v_orig uuid; v_rev_entry uuid;
  v_tb_before numeric; v_tb_after numeric;
  v_bs_before numeric; v_bs_after numeric;
  v_ledger1 record; v_ledger2 record;
  r record;
begin
  v_cur := (select base_currency_id from organizations where id = v_org);
  select id into v_cash from accounts where org_id = v_org and code = '11101';
  select id into v_rev  from accounts where org_id = v_org and code = '61101';

  select create_journal_entry(v_org, v_date_jan10, 'قيد أصلي بتاريخ 10 يناير',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 100, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 100, 'currency_id', v_cur)
    )) into v_orig;
  perform post_journal_entry(v_orig);

  -- 3) trial_balance في 31 يناير يعرض 100 (before the void even exists)
  select balance into v_tb_before from trial_balance(v_org, v_date_jan31) where account_id = v_cash;
  assert v_tb_before = 100, 'trial_balance as of Jan31 (before any void) should show 100, got ' || v_tb_before;

  select amount into v_bs_before from balance_sheet(v_org, v_date_jan31) where account_id = v_cash;
  assert v_bs_before = 100, 'balance_sheet as of Jan31 (before any void) should show 100, got ' || v_bs_before;

  -- void it, with the reversal dated a month later
  v_rev_entry := void_journal_entry(v_orig, v_date_feb10, 'اختبار: التأكد من عدم اختفاء القيد الملغى من التقارير');
  assert (select status from journal_entries where id = v_orig) = 'void', 'the original entry should now be status=void';
  assert (select status from journal_entries where id = v_rev_entry) = 'posted', 'the reversal entry should be status=posted';

  -- =========================================================================
  -- 12) the later void must NOT retroactively change the already-checked
  --     January report (this is the core bug: entry_date decides scope,
  --     not current status)
  -- =========================================================================
  select balance into v_tb_after from trial_balance(v_org, v_date_jan31) where account_id = v_cash;
  assert v_tb_after = v_tb_before, 'a later void must not retroactively change the January trial_balance — was ' || v_tb_before || ', now ' || v_tb_after;

  select amount into v_bs_after from balance_sheet(v_org, v_date_jan31) where account_id = v_cash;
  assert v_bs_after = v_bs_before, 'a later void must not retroactively change the January balance_sheet — was ' || v_bs_before || ', now ' || v_bs_after;

  -- =========================================================================
  -- 4) trial_balance after Feb10 nets to zero. Per project note: the row
  --    may still appear (real debit AND credit totals both nonzero — 100
  --    debit from the original, 100 credit from the reversal) but the net
  --    `balance` column must be exactly 0, not require the row to vanish.
  -- =========================================================================
  select debit, credit, balance into r from trial_balance(v_org, v_date_feb28) where account_id = v_cash;
  assert r.balance = 0, 'trial_balance as of Feb28 should net to a 0 balance, got ' || r.balance;
  assert r.debit = 100 and r.credit = 100, 'trial_balance as of Feb28 should show real debit=100/credit=100 totals even though balance=0, got debit=' || r.debit || ' credit=' || r.credit;

  -- =========================================================================
  -- 6) balance_sheet after the reversal nets to exactly 0 for cash — here
  --    the single signed sum is exactly 0, so (unlike trial_balance) the
  --    row itself disappears under the existing HAVING <> 0 filter; that
  --    disappearance IS the "nets to zero" proof for this function
  -- =========================================================================
  assert not exists (select 1 from balance_sheet(v_org, v_date_feb28) where account_id = v_cash),
    'balance_sheet as of Feb28 should show no residual cash row once debit and credit fully offset';

  -- =========================================================================
  -- 7) UNCLOSED before the reversal reflects the original result; after,
  --    it returns to zero (the UNCLOSED row always exists, unlike account
  --    rows, so this is a plain amount check both times)
  -- =========================================================================
  select amount into r from balance_sheet(v_org, v_date_jan31) where category_code = 'UNCLOSED';
  assert r.amount = 100, 'UNCLOSED as of Jan31 (before void) should reflect the original 100, got ' || r.amount;

  select amount into r from balance_sheet(v_org, v_date_feb28) where category_code = 'UNCLOSED';
  assert r.amount = 0, 'UNCLOSED as of Feb28 (after the reversal) should net back to 0, got ' || r.amount;

  -- =========================================================================
  -- 8) income_statement for January alone still shows the original 100
  -- =========================================================================
  select amount into r from income_statement(v_org, make_date(v_year,1,1), v_date_jan31) where account_id = v_rev;
  assert r.amount = 100, 'income_statement for January alone should show the original 100, got ' || r.amount;

  -- =========================================================================
  -- 9) income_statement across January+February nets to exactly 0 for the
  --    whole income section (works whether or not the individual account
  --    row survives the HAVING filter)
  -- =========================================================================
  select coalesce(sum(amount), 0) into v_tb_after from income_statement(v_org, make_date(v_year,1,1), v_date_feb28) where section = 'income';
  assert v_tb_after = 0, 'income_statement across Jan+Feb should net the income section to 0, got ' || v_tb_after;

  -- =========================================================================
  -- 10) account_ledger shows BOTH the voided original and the posted
  --     reversal, in date order, with the running balance reaching 100
  --     and returning to 0
  -- =========================================================================
  assert (select count(*) from account_ledger(v_cash, null, null)) = 2,
    'account_ledger for the cash account should show exactly 2 lines (the voided original and its reversal)';

  select * into v_ledger1 from account_ledger(v_cash, null, null) order by entry_date asc limit 1;
  assert v_ledger1.entry_date = v_date_jan10 and v_ledger1.debit = 100 and v_ledger1.credit = 0 and v_ledger1.running = 100,
    'account_ledger''s first line should be the original: Jan10, debit=100, credit=0, running=100 — got date=' || v_ledger1.entry_date || ' debit=' || v_ledger1.debit || ' credit=' || v_ledger1.credit || ' running=' || v_ledger1.running;

  select * into v_ledger2 from account_ledger(v_cash, null, null) order by entry_date desc limit 1;
  assert v_ledger2.entry_date = v_date_feb10 and v_ledger2.debit = 0 and v_ledger2.credit = 100 and v_ledger2.running = 0,
    'account_ledger''s second line should be the reversal: Feb10, debit=0, credit=100, running=0 — got date=' || v_ledger2.entry_date || ' debit=' || v_ledger2.debit || ' credit=' || v_ledger2.credit || ' running=' || v_ledger2.running;

  -- =========================================================================
  -- 11) account_balance() directly: 100 before the reversal, 0 after
  -- =========================================================================
  assert account_balance(v_cash, v_date_jan31) = 100, 'account_balance as of Jan31 should be 100';
  assert account_balance(v_cash, v_date_feb28) = 0, 'account_balance as of Feb28 should be 0 after the reversal';

  raise notice 'VOID/REVERSAL REPORTING OK';
end $$;

-- ============================================================================
-- BLOCK 2 — account_balance()/chart_of_accounts_balances() day-level
-- precision within a single fiscal period (the same class of bug fixed
-- for the main reports in 20250911004400, now closed for these two
-- helper functions too).
-- ============================================================================
do $$
declare
  v_org uuid := create_organization('MIDPRECORG', 'مؤسسة اختبار دقة منتصف الشهر');
  v_year int := extract(year from now())::int;
  v_date_5  date := make_date(v_year, 4, 5);
  v_date_15 date := make_date(v_year, 4, 15);
  v_date_25 date := make_date(v_year, 4, 25);
  v_date_30 date := make_date(v_year, 4, 30);
  v_cash uuid; v_cash_group uuid; v_rev uuid;
  v_cur uuid;
  v_entry uuid;
  v_bal numeric;
begin
  v_cur := (select base_currency_id from organizations where id = v_org);
  select id into v_cash       from accounts where org_id = v_org and code = '11101';
  select id into v_cash_group from accounts where org_id = v_org and code = '11100'; -- الصناديق والنقدية (parent group)
  select id into v_rev        from accounts where org_id = v_org and code = '61101';

  -- entry on day 5
  select create_journal_entry(v_org, v_date_5, 'قيد اليوم 5',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 60, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 60, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- entry on day 25 (SAME fiscal period as day 5 and day 15)
  select create_journal_entry(v_org, v_date_25, 'قيد اليوم 25',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 90, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 90, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- account_balance() as of day 15 must exclude day 25's posting
  v_bal := account_balance(v_cash, v_date_15);
  assert v_bal = 60, 'account_balance as of day 15 should exclude day 25''s posting (60, not 150), got ' || v_bal;

  v_bal := account_balance(v_cash, v_date_30);
  assert v_bal = 150, 'account_balance as of day 30 should include both postings (150), got ' || v_bal;

  -- chart_of_accounts_balances() as of day 15: the leaf account...
  select balance into v_bal from chart_of_accounts_balances(v_org, v_date_15) where account_id = v_cash;
  assert v_bal = 60, 'chart_of_accounts_balances (leaf) as of day 15 should exclude day 25''s posting, got ' || v_bal;

  -- ...and the parent GROUP account it rolls up to
  select balance into v_bal from chart_of_accounts_balances(v_org, v_date_15) where account_id = v_cash_group;
  assert v_bal = 60, 'chart_of_accounts_balances (parent group rollup) as of day 15 should exclude day 25''s posting, got ' || v_bal;

  select balance into v_bal from chart_of_accounts_balances(v_org, v_date_30) where account_id = v_cash_group;
  assert v_bal = 150, 'chart_of_accounts_balances (parent group rollup) as of day 30 should include both postings, got ' || v_bal;

  raise notice 'MID-MONTH HELPER PRECISION OK';
end $$;

-- ============================================================================
-- BLOCK 3 — real-world impact check ("إن أمكن"): ar_aging_detail() calls
-- account_balance() to compute a dealer's as-of balance. A receipt posted
-- mid-period, between two as-of dates in the SAME fiscal period, must be
-- correctly in or out of scope depending on p_as_of.
-- ============================================================================
do $$
declare
  v_org uuid := create_organization('AGEPRECORG', 'مؤسسة اختبار دقة الأعمار');
  v_year int := extract(year from now())::int;
  v_date_open  date := make_date(v_year, 3, 1);
  v_date_inv   date := make_date(v_year, 5, 1);
  v_date_before_receipt date := make_date(v_year, 5, 10);
  v_date_receipt date := make_date(v_year, 5, 20);
  v_date_after_receipt date := make_date(v_year, 5, 25);
  v_wh uuid; v_item uuid; v_cust uuid; v_cust_ctrl uuid; v_cust_acc uuid;
  v_cash uuid; v_inv_acc uuid; v_cogs_acc uuid; v_rev uuid; v_vat_out uuid; v_equity uuid;
  v_invoice uuid; v_receipt uuid;
  v_cur uuid;
  r record;
begin
  v_cur := (select base_currency_id from organizations where id = v_org);
  select id into v_cash    from accounts where org_id = v_org and code = '11101';
  select id into v_inv_acc from accounts where org_id = v_org and code = '11601';
  select id into v_cogs_acc from accounts where org_id = v_org and code = '51101';
  select id into v_rev     from accounts where org_id = v_org and code = '61101';
  select id into v_vat_out from accounts where org_id = v_org and code = '31401';
  select id into v_equity  from accounts where org_id = v_org and code = '41001';
  select id into v_cust_ctrl from accounts where org_id = v_org and code = '11501';

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'المستودع الرئيسي') returning id into v_wh;
  v_cust := create_dealer(v_org, 'عميل اختبار الأعمار', v_cust_ctrl, p_is_customer := true);
  select account_id into v_cust_acc from dealers where id = v_cust;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'AGESKU', 'صنف اختبار الأعمار', v_inv_acc, v_cogs_acc, v_rev, 100)
  returning id into v_item;

  perform post_stock_move(create_stock_move(v_org, 'opening', v_date_open, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 10))),
    v_equity);

  -- one credit invoice: 100 subtotal + 16 VAT = 116, dated May 1
  v_invoice := create_sales_invoice(v_org, v_date_inv, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 100)));
  perform post_sales_invoice(v_invoice, p_output_vat_account_id := v_vat_out);

  -- as of May10 (before any receipt): full 116 still open
  select open_amount into r from ar_aging_detail(v_org, v_date_before_receipt) where invoice_id = v_invoice;
  assert r.open_amount = 116, 'ar_aging_detail as of May10 (before the receipt) should show the full 116 open, got ' || r.open_amount;

  -- a 50 receipt posted May20 (mid-period, between the two as-of checks)
  v_receipt := create_voucher(v_org, 'receipt', v_date_receipt, 'تحصيل جزئي', v_cash, v_cur,
    jsonb_build_array(jsonb_build_object('account_id', v_cust_acc, 'amount', 50, 'dealer_id', v_cust)));
  perform post_voucher(v_receipt);

  -- as of May10 again: the May20 receipt must NOT leak backwards
  select open_amount into r from ar_aging_detail(v_org, v_date_before_receipt) where invoice_id = v_invoice;
  assert r.open_amount = 116, 'ar_aging_detail as of May10 must still show 116 even after a LATER (May20) receipt exists — got ' || r.open_amount;

  -- as of May25 (after the receipt): only 66 remains open
  select open_amount into r from ar_aging_detail(v_org, v_date_after_receipt) where invoice_id = v_invoice;
  assert r.open_amount = 66, 'ar_aging_detail as of May25 (after the receipt) should show 66 open (116-50), got ' || r.open_amount;

  raise notice 'AR AGING DATE PRECISION OK';
end $$;

rollback;
