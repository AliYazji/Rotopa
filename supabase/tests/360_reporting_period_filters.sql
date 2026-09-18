-- Regression coverage for 20250911004100_reporting_period_filter_fix.sql.
--
-- Before the fix, trial_balance()/income_statement()/balance_sheet() (and
-- balance_sheet()'s UNCLOSED line) put the date predicate inside the ON
-- clause of a LEFT JOIN to fiscal_periods — a failing ON condition on a
-- LEFT JOIN only nulls the right side, it does NOT drop the left-side
-- account_period_balances row from the SUM(). Every report was silently
-- cumulative-from-inception no matter what date was passed. This test
-- posts real entries into two different fiscal periods and proves each
-- report only counts the periods it should.
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
  v_cash uuid; v_rev uuid;
  v_cur uuid := (select base_currency_id from organizations where id = v_org);
  v_entry uuid;
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

  -- =========================================================================
  -- 1) trial_balance(): a date inside period A must not see period B's
  --    postings (the exact bug — LEFT JOIN ON-clause filter didn't drop
  --    the balance row)
  -- =========================================================================
  select balance into r from trial_balance(v_org, v_date_a) where account_id = v_cash;
  assert r.balance = 1000, 'trial_balance as of March should only see the 1000 March entry, got ' || r.balance;

  select balance into r from trial_balance(v_org, null) where account_id = v_cash;
  assert r.balance = 3000, 'trial_balance with p_as_of=null should be the cumulative total (3000), got ' || r.balance;

  -- =========================================================================
  -- 2) income_statement(): a [from, to] window inside period B must not
  --    include period A's revenue
  -- =========================================================================
  select amount into r from income_statement(v_org, v_date_b, v_date_b) where account_id = v_rev;
  assert r.amount = 2000, 'income_statement for the June window should only show June''s 2000, got ' || r.amount;

  assert not exists (
    select 1 from income_statement(v_org, v_date_b, v_date_b) where account_id = v_rev and amount = 3000
  ), 'income_statement for the June window must not leak March''s revenue';

  select amount into r from income_statement(v_org, v_date_a, v_date_a) where account_id = v_rev;
  assert r.amount = 1000, 'income_statement for the March window should only show March''s 1000, got ' || r.amount;

  -- =========================================================================
  -- 3) balance_sheet(): an as-of date inside period A must not include
  --    period B's later movement, in both the account row and UNCLOSED
  -- =========================================================================
  select amount into r from balance_sheet(v_org, v_date_a) where account_id = v_cash;
  assert r.amount = 1000, 'balance_sheet as of March should only show the 1000 March cash movement, got ' || r.amount;

  select amount into r from balance_sheet(v_org, v_date_a) where category_code = 'UNCLOSED';
  assert r.amount = 1000, 'UNCLOSED as of March should only reflect March''s 1000 net income, got ' || r.amount;

  select amount into r from balance_sheet(v_org, v_date_b) where category_code = 'UNCLOSED';
  assert r.amount = 3000, 'UNCLOSED as of June should reflect both periods'' 3000 net income, got ' || r.amount;

  -- =========================================================================
  -- 4) p_as_of/p_from/p_to = null still returns the cumulative total (no
  --    regression on the existing "whole history" use case)
  -- =========================================================================
  select amount into r from balance_sheet(v_org, null) where account_id = v_cash;
  assert r.amount = 3000, 'balance_sheet with p_as_of=null should be the cumulative 3000, got ' || r.amount;

  select amount into r from income_statement(v_org, null, null) where account_id = v_rev;
  assert r.amount = 3000, 'income_statement with null window should be the cumulative 3000, got ' || r.amount;

  raise notice 'REPORTING PERIOD FILTERS OK';
end $$;

rollback;
