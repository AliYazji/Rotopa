-- create_organization() now takes an optional p_sector parameter that picks
-- which chart-of-accounts template gets seeded (organizations.sector).
-- Covers the new manufacturing template (233 accounts, 46 categories, cost
-- split into direct materials/direct labor/overhead) and — critically — that
-- omitting p_sector (or passing 'restaurant_hotel' explicitly) still seeds
-- the original 285-account chart unchanged, since adding a 6th parameter to
-- create_organization() is the same orphaned-overload risk already hit twice
-- this project (app.vat_rate(), create_sales_invoice()).
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-000d-000000000001','owner@coa3.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-000d-000000000001', true);
set local role authenticated;
select set_config('t.org_mfg', create_organization('MFGORG','مصنع اختبار', 'NIS','شيكل',1,'manufacturing')::text, true);
select set_config('t.org_default', create_organization('DEFORG','مؤسسة اختبار افتراضية')::text, true);
select set_config('t.org_explicit', create_organization('RESTORG','مطعم اختبار صريح','NIS','شيكل',1,'restaurant_hotel')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org_mfg')::uuid;
  v_def uuid := current_setting('t.org_default')::uuid;
  v_rest uuid := current_setting('t.org_explicit')::uuid;
  v_ar_group uuid; v_ap_group uuid; v_emp_group uuid;
  v_dealer uuid; v_dealer_acc uuid;
  v_entry uuid; v_cur uuid;
begin
  -- =========================================================================
  -- 1) sector is recorded, and the manufacturing template seeds its own
  --    counts (not the restaurant/hotel ones)
  -- =========================================================================
  assert (select sector from organizations where id = v_org) = 'manufacturing', 'org should record sector=manufacturing';
  assert (select count(*) from account_categories where org_id = v_org) = 46, 'manufacturing chart should seed 46 categories';
  assert (select count(*) from accounts where org_id = v_org) = 233, 'manufacturing chart should seed 233 accounts';
  assert (select count(*) from accounts where org_id = v_org and parent_id is null) = 6,
    'manufacturing chart should have 6 top-level sections';
  assert not exists (
    select 1 from accounts a where a.org_id = v_org and a.is_postable
      and exists (select 1 from accounts c where c.parent_id = a.id)
  ), 'no postable account should have children';
  assert not exists (
    select 1 from accounts a where a.org_id = v_org and not a.is_postable and not a.is_control
      and not exists (select 1 from accounts c where c.parent_id = a.id)
  ), 'every non-control group should have at least one child';

  -- =========================================================================
  -- 2) control-account groups: customers (11401), employees (11500 — a
  --    direct group under 11000, unlike the restaurant/hotel chart's 115xx
  --    numbered pattern), local + import supplier groups (31101/31102)
  -- =========================================================================
  select id into v_ar_group from accounts where org_id = v_org and code = '11401';
  assert (select is_postable from accounts where id = v_ar_group) = false, '11401 should be a group';
  assert (select is_control from accounts where id = v_ar_group) = true, '11401 should be a control account';
  assert (select control_type from accounts where id = v_ar_group) = 'customers', '11401 control_type should be customers';
  assert (select category_id from accounts where id = v_ar_group) is not null, '11401 must have a category despite being a group';

  select id into v_emp_group from accounts where org_id = v_org and code = '11500';
  assert (select is_postable from accounts where id = v_emp_group) = false, '11500 should be a group';
  assert (select is_control from accounts where id = v_emp_group) = true, '11500 should be a control account';
  assert (select control_type from accounts where id = v_emp_group) = 'employees', '11500 control_type should be employees';
  assert (select category_id from accounts where id = v_emp_group) is not null, '11500 must have a category despite being a group';

  select id into v_ap_group from accounts where org_id = v_org and code = '31101';
  assert (select is_postable from accounts where id = v_ap_group) = false, '31101 should be a group';
  assert (select control_type from accounts where id = v_ap_group) = 'suppliers', '31101 control_type should be suppliers';
  assert (select control_type from accounts where org_id = v_org and code = '31102') = 'suppliers',
    '31102 (import suppliers) control_type should be suppliers too';

  -- =========================================================================
  -- 3) create_dealer() works against the manufacturing control groups, and
  --    the generated sub-account inherits the group's category
  -- =========================================================================
  v_dealer := create_dealer(v_org, 'موزع اختبار', v_ar_group, p_is_customer := true);
  select account_id into v_dealer_acc from dealers where id = v_dealer;
  assert (select category_id from accounts where id = v_dealer_acc) = (select category_id from accounts where id = v_ar_group),
    'the auto-created dealer sub-account should inherit the control group''s category';
  assert (select is_postable from accounts where id = v_dealer_acc) = true, 'the auto-created dealer sub-account should be postable';

  -- =========================================================================
  -- 4) chart_of_accounts_balances() rolls up through the control group to
  --    the root, and product revenue (PRODREV) posts correctly
  -- =========================================================================
  v_cur := (select base_currency_id from organizations where id = v_org);
  select create_journal_entry(v_org, current_date, 'قيد اختبار على موزع',
    jsonb_build_array(
      jsonb_build_object('account_id', v_dealer_acc, 'debit', 700, 'currency_id', v_cur),
      jsonb_build_object('account_id', (select id from accounts where org_id = v_org and code = '61101'), 'credit', 700, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  assert (select balance from chart_of_accounts_balances(v_org) where account_id = v_dealer_acc) = 700,
    'the dealer''s own account should show 700';
  assert (select balance from chart_of_accounts_balances(v_org) where account_id = v_ar_group) = 700,
    'the control-account group should roll up the dealer''s posting';
  assert (select balance from chart_of_accounts_balances(v_org) where account_id = (select id from accounts where org_id=v_org and code='10000')) = 700,
    'الأصول (root) should roll up the whole subtree';

  -- =========================================================================
  -- 5) regression: omitting p_sector, or passing 'restaurant_hotel'
  --    explicitly, must still seed the original 285-account chart unchanged
  -- =========================================================================
  assert (select sector from organizations where id = v_def) = 'restaurant_hotel', 'default org should default to sector=restaurant_hotel';
  assert (select count(*) from accounts where org_id = v_def) = 285, 'default-sector org should still seed the 285-account chart';
  assert (select count(*) from account_categories where org_id = v_def) = 46, 'default-sector org should still seed 46 categories';

  assert (select sector from organizations where id = v_rest) = 'restaurant_hotel', 'explicit restaurant_hotel org should record it';
  assert (select count(*) from accounts where org_id = v_rest) = 285, 'explicit restaurant_hotel org should seed the 285-account chart';

  raise notice 'MANUFACTURING SECTOR CHART OF ACCOUNTS OK';
end $$;

rollback;
