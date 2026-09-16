-- chart_of_accounts_balances() — one balance per account for the /accounts
-- browsing screen, including group/parent rows (rolled up from every
-- postable descendant) and zero-balance accounts (present, not missing).
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fb000000-0000-0000-000b-000000000001','owner@coa.test');
select set_config('request.jwt.claim.sub','fb000000-0000-0000-000b-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('COAORG','مؤسسة اختبار دليل الحسابات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_root uuid; v_group uuid; v_leaf1 uuid; v_leaf2 uuid; v_leaf3 uuid; v_income uuid;
  v_cur uuid := (select base_currency_id from organizations where id = v_org);
  v_entry uuid;
  m jsonb;
  v_before_count int;
begin
  select count(*) from chart_of_accounts_balances(v_org) into v_before_count;

  -- Z-prefixed: create_organization() now seeds a real default chart of
  -- accounts (20250911003800) using plain 10000-65999 numeric codes, so
  -- this test's own scratch tree needs codes that can't collide with it
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'Z1000','الأصول',false,'debit') returning id into v_root;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'Z1010','مجموعة فرعية',v_root,false,'debit') returning id into v_group;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'Z1011','حساب 1',v_group,true,'debit') returning id into v_leaf1;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'Z1012','حساب 2',v_group,true,'debit') returning id into v_leaf2;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'Z1020','حساب بلا حركة',v_root,true,'debit') returning id into v_leaf3;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'Z4000','إيرادات',true,'credit') returning id into v_income;

  select create_journal_entry(v_org, current_date, 'قيد اختبار',
    jsonb_build_array(
      jsonb_build_object('account_id', v_leaf1, 'debit', 600, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_leaf2, 'debit', 400, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_income, 'credit', 1000, 'currency_id', v_cur)
    )) into v_entry;
  perform post_journal_entry(v_entry);

  select jsonb_object_agg(account_id::text, balance) into m from chart_of_accounts_balances(v_org);

  assert (m->>v_leaf1::text)::numeric = 600, 'leaf1 balance should be 600';
  assert (m->>v_leaf2::text)::numeric = 400, 'leaf2 balance should be 400';
  assert (m->>v_leaf3::text)::numeric = 0, 'a never-posted leaf should show 0, not be missing';
  assert (m->>v_group::text)::numeric = 1000, 'the group account should roll up its two postable children (600+400)';
  assert (m->>v_root::text)::numeric = 1000, 'the root account should roll up the whole subtree (group''s 1000 + the zero sibling)';
  assert (m->>v_income::text)::numeric = -1000, 'the credit-natured income account should show -1000';

  -- every account in the org appears, none silently missing — exactly 6
  -- more rows than before this test added its own 6 scratch accounts
  assert (select count(*) from chart_of_accounts_balances(v_org)) = v_before_count + 6, 'every account (postable or group) should have a row';

  raise notice 'CHART OF ACCOUNTS BALANCES OK';
end $$;

rollback;
