-- Regression coverage requested alongside the reporting-precision fix:
-- prove the "contra account" display convention already documented in
-- docs/data-model.md actually produces the right accounting result,
-- WITHOUT adding any is_contra column or touching normal_balance/nature —
-- this is a verification test, not a fix. A contra account (accumulated
-- depreciation, owner draws, sales discounts/returns) is deliberately
-- filed under its "sibling" category's own section with that category's
-- OWN normal_balance (asset/debit for ACCDEP, equity/credit for DRAW,
-- income/credit for CONTRA_REV) even though the individual account's own
-- `nature` is the opposite — so a normal posting to it naturally comes out
-- negative in trial_balance()/balance_sheet()/income_statement(), with no
-- special-casing needed in the report functions themselves.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-0010-000000000001','owner@contra.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-0010-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('CONTRAORG','مؤسسة اختبار الحسابات المقابلة')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_deprexp uuid; v_accdep uuid; v_draw uuid; v_contra uuid; v_rev uuid;
  v_cur uuid := (select base_currency_id from organizations where id = v_org);
  v_entry uuid;
  v_total numeric;
  r record;
begin
  select id into v_cash    from accounts where org_id = v_org and code = '11101';
  select id into v_deprexp from accounts where org_id = v_org and code = '53501'; -- إهلاك المباني الإدارية (DEPR, expense)
  select id into v_accdep  from accounts where org_id = v_org and code = '22101'; -- مجمع إهلاك المباني (ACCDEP, contra-asset)
  select id into v_draw    from accounts where org_id = v_org and code = '45001'; -- مسحوبات المالك (DRAW, contra-equity)
  select id into v_contra  from accounts where org_id = v_org and code = '64101'; -- خصم مسموح به للعملاء (CONTRA_REV, contra-income)
  select id into v_rev     from accounts where org_id = v_org and code = '61101';

  -- =========================================================================
  -- 1) ACCDEP: a normal depreciation posting (debit expense, credit
  --    accumulated depreciation — a real credit balance on a debit-normal-
  --    section account) must show up NEGATIVE under assets
  -- =========================================================================
  select create_journal_entry(v_org, current_date, 'قيد إهلاك',
    jsonb_build_array(
      jsonb_build_object('account_id', v_deprexp, 'debit', 200, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_accdep,  'credit', 200, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  -- the raw ledger stores the natural, unsigned credit — proves the sign
  -- flip happens exactly once, in the report function, never in the data
  assert exists (select 1 from account_ledger(v_accdep) where credit = 200 and debit = 0),
    'the raw journal line for accumulated depreciation should be a plain unsigned credit of 200';

  select amount into r from balance_sheet(v_org, null) where account_id = v_accdep;
  assert r.amount = -200, 'accumulated depreciation (ACCDEP, credit balance) should show as -200 under assets, got ' || r.amount;
  assert (select section from balance_sheet(v_org, null) where account_id = v_accdep) = 'asset',
    'accumulated depreciation should still be filed under the asset section, just negative';

  -- =========================================================================
  -- 2) DRAW: an owner draw (debit — money leaving the business to the
  --    owner) must show up NEGATIVE under equity
  -- =========================================================================
  select create_journal_entry(v_org, current_date, 'سحب المالك',
    jsonb_build_array(
      jsonb_build_object('account_id', v_draw, 'debit', 150, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_cash, 'credit', 150, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  assert exists (select 1 from account_ledger(v_draw) where debit = 150 and credit = 0),
    'the raw journal line for the owner draw should be a plain unsigned debit of 150';

  select amount into r from balance_sheet(v_org, null) where account_id = v_draw;
  assert r.amount = -150, 'owner draws (DRAW, debit balance) should show as -150 under equity, got ' || r.amount;
  assert (select section from balance_sheet(v_org, null) where account_id = v_draw) = 'equity',
    'owner draws should still be filed under the equity section, just negative';

  -- =========================================================================
  -- 3) CONTRA_REV: a sales discount (debit — reduces revenue) must show up
  --    NEGATIVE under income, and must actually reduce the income
  --    section's net total (not just display negative in isolation)
  -- =========================================================================
  select create_journal_entry(v_org, current_date, 'مبيعات',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 1000, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 1000, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  select create_journal_entry(v_org, current_date, 'خصم مسموح به لعميل',
    jsonb_build_array(
      jsonb_build_object('account_id', v_contra, 'debit', 50, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_cash,    'credit', 50, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  assert exists (select 1 from account_ledger(v_contra) where debit = 50 and credit = 0),
    'the raw journal line for the sales discount should be a plain unsigned debit of 50';

  select amount into r from income_statement(v_org, null, null) where account_id = v_contra;
  assert r.amount = -50, 'the sales discount (CONTRA_REV, debit balance) should show as -50 within income, got ' || r.amount;
  assert (select section from income_statement(v_org, null, null) where account_id = v_contra) = 'income',
    'the sales discount should still be filed under the income section, just negative';

  select coalesce(sum(amount), 0) into v_total from income_statement(v_org, null, null) where section = 'income';
  assert v_total = 950, 'net revenue (1000 sale - 50 discount) should be 950, got ' || v_total;

  raise notice 'CONTRA ACCOUNT SIGNS OK';
end $$;

rollback;
