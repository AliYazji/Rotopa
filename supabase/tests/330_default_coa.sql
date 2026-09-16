-- create_organization() now seeds a real chart of accounts (285 accounts,
-- 46 categories) instead of leaving a brand-new org with zero. Covers tree
-- integrity, the 5 control-account groups (is_postable=false despite the
-- source calling them "ترحيل"), and that create_dealer() + the balance
-- rollup from chart_of_accounts_balances() both work correctly against it.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-000c-000000000001','owner@coa2.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-000c-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('NEWORG','مؤسسة اختبار الدليل الجديد','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_ar_group uuid; v_ap_group uuid; v_dealer uuid; v_dealer_acc uuid;
  v_entry uuid; v_cur uuid := (select base_currency_id from organizations where id = v_org);
begin
  -- =========================================================================
  -- 1) counts and tree integrity
  -- =========================================================================
  assert (select count(*) from account_categories where org_id = v_org) = 46, 'should seed 46 categories';
  assert (select count(*) from accounts where org_id = v_org) = 285, 'should seed 285 accounts';
  assert (select count(*) from accounts where org_id = v_org and parent_id is null) = 6,
    'should have 6 top-level sections (assets/non-current assets/liabilities/equity/costs/revenue)';
  assert not exists (
    select 1 from accounts a where a.org_id = v_org and a.is_postable
      and exists (select 1 from accounts c where c.parent_id = a.id)
  ), 'no postable account should have children';
  -- control-account groups (11501/11502/11504/31101/31102) are the one
  -- deliberate exception: they start empty and only gain children once a
  -- real customer/supplier/employee is created via create_dealer()
  assert not exists (
    select 1 from accounts a where a.org_id = v_org and not a.is_postable and not a.is_control
      and not exists (select 1 from accounts c where c.parent_id = a.id)
  ), 'every non-control group account should have at least one child (no dangling empty groups)';

  -- =========================================================================
  -- 2) control-account groups: is_postable=false despite the source file
  --    calling them "ترحيل", is_control=true, and — critically — a real
  --    category_id so dealer sub-accounts don't vanish from the reports
  -- =========================================================================
  select id into v_ar_group from accounts where org_id = v_org and code = '11501';
  assert (select is_postable from accounts where id = v_ar_group) = false, '11501 should be a group, not postable';
  assert (select is_control from accounts where id = v_ar_group) = true, '11501 should be flagged as a control account';
  assert (select control_type from accounts where id = v_ar_group) = 'customers', '11501 control_type should be customers';
  assert (select category_id from accounts where id = v_ar_group) is not null, '11501 must have a category despite being a group';

  select id into v_ap_group from accounts where org_id = v_org and code = '31101';
  assert (select is_postable from accounts where id = v_ap_group) = false, '31101 should be a group, not postable';
  assert (select control_type from accounts where id = v_ap_group) = 'suppliers', '31101 control_type should be suppliers';

  -- =========================================================================
  -- 3) create_dealer() works against the new control-account groups, and
  --    the generated sub-account inherits the group's category
  -- =========================================================================
  v_dealer := create_dealer(v_org, 'زبون اختبار', v_ar_group, p_is_customer := true);
  select account_id into v_dealer_acc from dealers where id = v_dealer;
  assert (select category_id from accounts where id = v_dealer_acc) = (select category_id from accounts where id = v_ar_group),
    'the auto-created dealer sub-account should inherit the control group''s category';
  assert (select is_postable from accounts where id = v_dealer_acc) = true, 'the auto-created dealer sub-account should be postable';

  -- =========================================================================
  -- 4) chart_of_accounts_balances() rolls up a real posting through the
  --    dealer's own account up to the control group and the whole tree
  -- =========================================================================
  select create_journal_entry(v_org, current_date, 'قيد اختبار على عميل',
    jsonb_build_array(
      jsonb_build_object('account_id', v_dealer_acc, 'debit', 500, 'currency_id', v_cur),
      jsonb_build_object('account_id', (select id from accounts where org_id = v_org and code = '61101'), 'credit', 500, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  assert (select balance from chart_of_accounts_balances(v_org) where account_id = v_dealer_acc) = 500,
    'the dealer''s own account should show 500';
  assert (select balance from chart_of_accounts_balances(v_org) where account_id = v_ar_group) = 500,
    'the control-account group should roll up the dealer''s posting';
  assert (select balance from chart_of_accounts_balances(v_org) where account_id = (select id from accounts where org_id=v_org and code='11500')) = 500,
    'الذمم المدينة should roll up through the control group';
  assert (select balance from chart_of_accounts_balances(v_org) where account_id = (select id from accounts where org_id=v_org and code='10000')) = 500,
    'الأصول (root) should roll up the whole subtree';

  raise notice 'DEFAULT CHART OF ACCOUNTS OK';
end $$;

rollback;
