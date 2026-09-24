-- Regression coverage for 20250911004100_reporting_period_filter_fix.sql
-- AND 20250911004400_reporting_entry_date_precision.sql.
--
-- Before the first fix, trial_balance()/income_statement()/balance_sheet()
-- (and balance_sheet()'s UNCLOSED line) put the date predicate inside the
-- ON clause of a LEFT JOIN to fiscal_periods — a failing ON condition on a
-- LEFT JOIN only nulls the right side, it does NOT drop the left-side
-- account_period_balances row from the SUM(). Every report was silently
-- cumulative-from-inception no matter what date was passed.
--
-- That first fix only reached PERIOD granularity though: it summed a
-- whole account_period_balances row once the period's start_date matched
-- p_as_of, with no lower bound inside the period itself — a posting on
-- the 25th of a month still showed up in a report as-of the 15th of that
-- SAME month. The second fix sums posted journal_lines directly by their
-- real entry_date instead of relying on the monthly rollup, closing that
-- gap, and — since it stops looking at fiscal_periods.status entirely —
-- also proves a closed period's income/expense still counts in UNCLOSED
-- (closing a period only blocks new postings into it here, it does not
-- run a year-end closing entry).
--
-- This file posts entries into two different fiscal periods AND multiple
-- days within the SAME period, and proves each report only counts what it
-- should down to the exact entry_date.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-000e-000000000001','owner@periods.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-000e-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PERIODORG','مؤسسة اختبار فلترة الفترات')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_year int := extract(year from now())::int;
  v_date_a date := make_date(v_year, 3, 10);   -- period A: March
  v_date_b date := make_date(v_year, 6, 10);   -- period B: June
  v_date_c date := make_date(v_year, 3, 5);    -- earlier in the SAME period as A
  v_date_mid date := make_date(v_year, 3, 15); -- as-of boundary between C/A and D
  v_date_d date := make_date(v_year, 3, 25);   -- later in the SAME period as A
  v_date_jan date := make_date(v_year, 1, 20); -- inside period_no=1, will be closed
  v_cash uuid; v_rev uuid;
  v_cur uuid := (select base_currency_id from organizations where id = v_org);
  v_entry uuid;
  v_jan_period uuid;
  r record;
begin
  select id into v_cash from accounts where org_id = v_org and code = '11101';
  select id into v_rev  from accounts where org_id = v_org and code = '61101';

  -- entry A: 1000 in March
  select create_journal_entry(v_org, v_date_a, 'قيد فترة آذار',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 1000, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 1000, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- entry B: 2000 in June
  select create_journal_entry(v_org, v_date_b, 'قيد فترة حزيران',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 2000, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 2000, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- entry C: 100, EARLIER in the same March period as A (day-level precision)
  select create_journal_entry(v_org, v_date_c, 'قيد آذار المبكر',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 100, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 100, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- entry D: 400, LATER in the same March period as A (day-level precision)
  select create_journal_entry(v_org, v_date_d, 'قيد آذار المتأخر',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 400, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 400, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- Running totals so far, for reference while reading the assertions below:
  --   March period postings: C(Mar5)=100, A(Mar10)=1000, D(Mar25)=400 -> period total 1500
  --   June period postings:  B(Jun10)=2000
  --   cumulative (all periods) = 3500

  -- =========================================================================
  -- 1) trial_balance(): a date inside period A must not see period B's
  --    postings (the cross-period bug), AND must not see a LATER posting
  --    inside the SAME period either (the day-level-precision bug — D on
  --    Mar25 must not show up as of Mar10, even though D's fiscal period
  --    start_date is well before Mar10)
  -- =========================================================================
  select balance into r from trial_balance(v_org, v_date_a) where account_id = v_cash;
  assert r.balance = 1100, 'trial_balance as of Mar10 should see C(100)+A(1000)=1100 but not D(400, Mar25) or B(June), got ' || r.balance;

  select balance into r from trial_balance(v_org, null) where account_id = v_cash;
  assert r.balance = 3500, 'trial_balance with p_as_of=null should be the cumulative total (3500), got ' || r.balance;

  -- =========================================================================
  -- 2) income_statement(): a [from, to] window inside period B must not
  --    include period A's revenue; and within period A, the window must
  --    respect entry_date, inclusive of both boundary dates
  -- =========================================================================
  select amount into r from income_statement(v_org, v_date_b, v_date_b) where account_id = v_rev;
  assert r.amount = 2000, 'income_statement for the June window should only show June''s 2000, got ' || r.amount;

  assert not exists (
    select 1 from income_statement(v_org, v_date_b, v_date_b) where account_id = v_rev and amount <> 2000
  ), 'income_statement for the June window must not leak March''s revenue';

  -- exact single-day window on Mar10: only A, not C (Mar5) or D (Mar25)
  select amount into r from income_statement(v_org, v_date_a, v_date_a) where account_id = v_rev;
  assert r.amount = 1000, 'income_statement for the exact Mar10 window should only show A''s 1000, got ' || r.amount;

  -- [Mar5, Mar15] inclusive of the Mar5 lower boundary (C): C+A, not D
  select amount into r from income_statement(v_org, v_date_c, v_date_mid) where account_id = v_rev;
  assert r.amount = 1100, 'income_statement for [Mar5,Mar15] should include C(100)+A(1000)=1100 but not D(400), got ' || r.amount;

  -- [Mar5, Mar25] inclusive of the Mar25 upper boundary (D): all of C+A+D
  select amount into r from income_statement(v_org, v_date_c, v_date_d) where account_id = v_rev;
  assert r.amount = 1500, 'income_statement for [Mar5,Mar25] should include the whole period (C+A+D=1500) including D exactly on the boundary, got ' || r.amount;

  -- =========================================================================
  -- 3) balance_sheet(): an as-of date inside period A must not include
  --    period B's later movement NOR a later same-period posting, in both
  --    the account row and UNCLOSED — this is the day-level-precision case
  --    the previous (period-only) fix still got wrong: D (Mar25) sat in
  --    the SAME fiscal period as the Mar15 as-of date, so a period-level
  --    filter alone would have wrongly included it
  -- =========================================================================
  select amount into r from balance_sheet(v_org, v_date_mid) where account_id = v_cash;
  assert r.amount = 1100, 'balance_sheet as of Mar15 should show C(100)+A(1000)=1100 but not D(400, Mar25 — later in the SAME period), got ' || r.amount;

  select amount into r from balance_sheet(v_org, v_date_mid) where category_code = 'UNCLOSED';
  assert r.amount = 1100, 'UNCLOSED as of Mar15 should reflect only C+A=1100, not D(400) which is later in the same period, got ' || r.amount;

  select amount into r from balance_sheet(v_org, v_date_b) where category_code = 'UNCLOSED';
  assert r.amount = 3500, 'UNCLOSED as of June should reflect all four postings (3500), got ' || r.amount;

  -- =========================================================================
  -- 4) p_as_of/p_from/p_to = null still returns the cumulative total (no
  --    regression on the existing "whole history" use case)
  -- =========================================================================
  select amount into r from balance_sheet(v_org, null) where account_id = v_cash;
  assert r.amount = 3500, 'balance_sheet with p_as_of=null should be the cumulative 3500, got ' || r.amount;

  select amount into r from income_statement(v_org, null, null) where account_id = v_rev;
  assert r.amount = 3500, 'income_statement with null window should be the cumulative 3500, got ' || r.amount;

  -- =========================================================================
  -- 5) closing a fiscal period must NOT remove its income/expense from
  --    UNCLOSED — this system's period closing only blocks new postings
  --    into that period (app.open_period_for), it does not run a year-end
  --    closing entry moving income/expense to retained earnings
  -- =========================================================================
  select id into v_jan_period from fiscal_periods where org_id = v_org and period_no = 1;

  select create_journal_entry(v_org, v_date_jan, 'قيد كانون الثاني قبل الإقفال',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 300, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 300, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  perform close_fiscal_period(v_jan_period, 'اختبار: التأكد أن الإقفال لا يخفي الحركة عن UNCLOSED');
  assert (select status from fiscal_periods where id = v_jan_period) = 'closed', 'January period should now be closed';

  -- as-of a date still inside the now-closed January period: its own 300
  -- must still count (an as-of date always includes its own day)
  select amount into r from balance_sheet(v_org, v_date_jan) where category_code = 'UNCLOSED';
  assert r.amount = 300, 'UNCLOSED as of Jan20 (now closed) should still show January''s own 300, got ' || r.amount;

  -- as-of a later date: January's 300 must still be counted alongside
  -- everything through that date, proving "closed" never excludes a period
  select amount into r from balance_sheet(v_org, v_date_b) where category_code = 'UNCLOSED';
  assert r.amount = 3800, 'UNCLOSED as of June should still include the closed January period''s 300 on top of the other 3500, got ' || r.amount;

  -- assets = liabilities + equity must still balance with a closed period
  -- in the mix (no schema/normal_balance change, just proving the report
  -- functions keep the accounting equation intact)
  assert (
    select coalesce(sum(amount), 0) from balance_sheet(v_org, v_date_b)
    where section = 'asset'
  ) = (
    select coalesce(sum(amount), 0) from balance_sheet(v_org, v_date_b)
    where section in ('liability', 'equity')
  ), 'assets should still equal liabilities + equity as of June with a closed period in the mix';

  raise notice 'REPORTING PERIOD FILTERS OK';
end $$;

rollback;
