-- End-to-end smoke test for the Phase 1 foundation.
-- Run after 00_shim.sql + all migrations. Any RAISE EXCEPTION fails the build.
\set ON_ERROR_STOP on
begin;

-- a signed-in user
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'owner@test');
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
set local role authenticated;

-- 1. bootstrap an org
select create_organization('ACME', 'شركة أكمي', 'NIS', 'شيكل', 1) as org \gset
select set_config('test.org', :'org', true);

do $$
declare
  v_org uuid := current_setting('test.org')::uuid;
  v_cash uuid; v_sales uuid; v_ar uuid; v_parent_assets uuid; v_parent_income uuid;
  v_cat_asset uuid; v_cat_income uuid;
  v_entry uuid;
begin
  -- 2. categories + a tiny chart of accounts
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance)
  values (v_org, 'CA', 'أصول متداولة', 'balance_sheet', 'asset', 'debit') returning id into v_cat_asset;
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance)
  values (v_org, 'REV', 'إيرادات', 'income_statement', 'income', 'credit') returning id into v_cat_income;

  insert into accounts (org_id, code, name_ar, is_postable, nature)
  values (v_org, '10000', 'الأصول المتداولة', false, 'debit') returning id into v_parent_assets;
  insert into accounts (org_id, code, name_ar, is_postable, nature)
  values (v_org, '40000', 'الإيرادات', false, 'credit') returning id into v_parent_income;

  insert into accounts (org_id, code, name_ar, parent_id, category_id, is_postable, nature)
  values (v_org, '10101', 'الصندوق', v_parent_assets, v_cat_asset, true, 'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, category_id, is_postable, nature)
  values (v_org, '10201', 'ذمم العملاء', v_parent_assets, v_cat_asset, true, 'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, category_id, is_postable, nature)
  values (v_org, '40101', 'مبيعات', v_parent_income, v_cat_income, true, 'credit') returning id into v_sales;

  -- tree upkeep
  assert (select depth from accounts where id = v_cash) = 1, 'cash depth should be 1';
  assert (select path::text from accounts where id = v_cash) = '10000.10101', 'cash path wrong';

  -- 3. can't add a child under a postable account
  begin
    insert into accounts (org_id, code, name_ar, parent_id, is_postable)
    values (v_org, '10101999', 'child of leaf', v_cash, true);
    raise exception 'TEST FAIL: allowed child under postable account';
  exception when sqlstate '23514' then null;
  end;

  -- 4. balanced entry via RPC, then post
  select create_journal_entry(
    v_org, current_date, 'بيع نقدي',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash,  'debit', 1000, 'currency_id', (select base_currency_id from organizations where id=v_org)),
      jsonb_build_object('account_id', v_sales, 'credit', 1000, 'currency_id', (select base_currency_id from organizations where id=v_org))
    )
  ) into v_entry;
  perform post_journal_entry(v_entry);
  assert (select status from journal_entries where id = v_entry) = 'posted', 'entry not posted';

  -- 5. roll-up updated
  assert account_balance(v_cash) = 1000, 'cash balance should be 1000';
  assert account_balance(v_sales) = -1000, 'sales balance should be -1000';

  -- 6. unbalanced entry must be rejected at post
  begin
    select create_journal_entry(
      v_org, current_date, 'قيد غير متوازن',
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash,  'debit', 500,  'currency_id', (select base_currency_id from organizations where id=v_org)),
        jsonb_build_object('account_id', v_sales, 'credit', 400, 'currency_id', (select base_currency_id from organizations where id=v_org))
      )
    ) into v_entry;
    perform post_journal_entry(v_entry);
    raise exception 'TEST FAIL: posted an unbalanced entry';
  exception when sqlstate '23514' then null;
  end;

  -- 7. posted entry is immutable
  begin
    update journal_entries set description = 'tampered' where id in (select id from journal_entries where status='posted' limit 1);
    raise exception 'TEST FAIL: edited a posted entry';
  exception when sqlstate '23514' then null;
  end;

  -- 8. void produces a reversing entry and zeroes the balance
  select id into v_entry from journal_entries where status = 'posted' and source_type = 'manual' order by entry_no limit 1;
  perform void_journal_entry(v_entry, current_date, 'اختبار');
  assert (select status from journal_entries where id = v_entry) = 'void', 'entry not void';
  assert account_balance(v_cash) = 0, 'cash balance should be 0 after void';

  raise notice 'SMOKE OK — org %, entries %', v_org, (select count(*) from journal_entries where org_id = v_org);
end $$;

rollback;
