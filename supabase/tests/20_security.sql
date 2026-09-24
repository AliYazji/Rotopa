-- Isolation & guard-rail tests. Run after 00_shim.sql + migrations.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-000000000001', 'a@test'),
  ('b0000000-0000-0000-0000-000000000002', 'b@test');

-- user A builds org A
select set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.orga', create_organization('ORGA', 'مؤسسة أ', 'NIS', 'شيكل', 1)::text, true);

do $$
declare v_org uuid := current_setting('t.orga')::uuid;
begin
  -- codes prefixed Z: create_organization() now seeds a real default chart
  -- of accounts (20250911003800) using plain 10000-65999 numeric codes, so
  -- this test's own scratch accounts need codes that can't collide with it
  insert into accounts (org_id, code, name_ar, is_postable, nature) values
    (v_org, 'Z1000', 'أصول', false, 'debit');
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values
    (v_org, 'Z1010', 'صندوق', (select id from accounts where org_id=v_org and code='Z1000'), true, 'debit'),
    (v_org, 'Z4010', 'مبيعات', (select id from accounts where org_id=v_org and code='Z1000'), true, 'credit');
end $$;

-- user B builds org B and must NOT see org A
select set_config('request.jwt.claim.sub', 'b0000000-0000-0000-0000-000000000002', true);
set local role authenticated;
select set_config('t.orgb', create_organization('ORGB', 'مؤسسة ب', 'USD', 'دولار', 1)::text, true);

do $$
declare
  v_orga uuid := current_setting('t.orga')::uuid;
  v_seen int;
begin
  select count(*) into v_seen from accounts where org_id = v_orga;
  assert v_seen = 0, format('RLS LEAK: user B saw %s of org A accounts', v_seen);

  select count(*) into v_seen from organizations where id = v_orga;
  assert v_seen = 0, 'RLS LEAK: user B saw org A';

  begin
    perform create_journal_entry(
      v_orga, current_date, 'محاولة اختراق',
      jsonb_build_array(
        jsonb_build_object('account_id', (select id from accounts where org_id=v_orga and code='Z1010'), 'debit', 1, 'currency_id', (select base_currency_id from organizations where id=v_orga)),
        jsonb_build_object('account_id', (select id from accounts where org_id=v_orga and code='Z4010'), 'credit', 1, 'currency_id', (select base_currency_id from organizations where id=v_orga))
      ));
    raise exception 'SECURITY FAIL: user B created an entry in org A';
  exception when sqlstate '42501' then null;
  end;

  raise notice 'ISOLATION OK';
end $$;

-- closed-period guard (back as user A)
select set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000001', true);
set local role authenticated;
do $$
declare
  v_org uuid := current_setting('t.orga')::uuid;
  v_pid uuid;
  v_cash uuid;
  v_sales uuid;
  v_base uuid;
  v_d date;
begin
  select id from accounts where org_id = v_org and code = 'Z1010' into v_cash;
  select id from accounts where org_id = v_org and code = 'Z4010' into v_sales;
  select base_currency_id from organizations where id = v_org into v_base;

  select id, start_date into v_pid, v_d from fiscal_periods
    where org_id = v_org order by start_date limit 1;
  update fiscal_periods set status = 'closed' where id = v_pid;

  begin
    perform create_journal_entry(v_org, v_d, 'في فترة مقفلة',
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash,  'debit', 10, 'currency_id', v_base),
        jsonb_build_object('account_id', v_sales, 'credit', 10, 'currency_id', v_base)));
    -- distinct errcode so this can never collide with the guard's own
    -- default P0001 (a same-code TEST FAIL would silently pass whether
    -- the guard fired or not)
    raise exception 'GUARD FAIL: created entry in a closed period' using errcode = '99001';
  exception when sqlstate 'P0001' then null;
  end;

  raise notice 'CLOSED-PERIOD GUARD OK';
end $$;

rollback;
