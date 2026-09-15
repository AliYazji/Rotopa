-- Audit log read surface: filtering by table/action/actor/record/date range,
-- pagination with total_count, actor email joined in, and permission gating.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f4000000-0000-0000-0004-000000000001','owner@audit.test'),
  ('f4000000-0000-0000-0004-000000000002','viewer@audit.test');

select set_config('request.jwt.claim.sub','f4000000-0000-0000-0004-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('AUDITORG','مؤسسة اختبار التدقيق','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_owner uuid := 'f4000000-0000-0000-0004-000000000001';
  v_viewer_role uuid;
  v_acc uuid;
  v_cur uuid;
  r record;
  v_total bigint;
  v_before_count int;
begin
  select count(*) into v_before_count from audit_log where org_id = v_org;

  -- generate a real INSERT/UPDATE/DELETE spread across two different tables
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org, 'AUD1', 'حساب اختبار', true, 'debit') returning id into v_acc;
  update accounts set name_ar = 'حساب اختبار معدّل' where id = v_acc;

  insert into currencies (org_id, code, name_ar, decimal_places) values (v_org, 'AUDUSD', 'دولار اختبار', 2) returning id into v_cur;
  delete from currencies where id = v_cur;

  -- =========================================================================
  -- 1) unfiltered query sees everything for this org, newest first, with total_count
  -- =========================================================================
  select count(*) into v_total from audit_log where org_id = v_org;
  select * into r from audit_log_query(v_org) limit 1;
  assert r.total_count = v_total, 'total_count should match the real row count for this org';
  assert v_total >= v_before_count + 4, 'should have at least the 4 new entries (insert+update accounts, insert+delete currency)';

  -- =========================================================================
  -- 2) filter by table_name
  -- =========================================================================
  -- 3 currency rows: the org's base currency (created by create_organization
  -- itself) plus this test's own insert+delete of AUDUSD
  assert (select count(*) from audit_log_query(v_org, p_table_name := 'currencies')) = 3, 'exactly 3 currency audit rows (base-currency insert + this test''s insert+delete)';
  assert (select count(*) from audit_log_query(v_org, p_table_name := 'accounts', p_record_id := v_acc::text)) = 2, 'exactly 2 audit rows for this specific account';

  -- =========================================================================
  -- 3) filter by action
  -- =========================================================================
  assert (select count(*) from audit_log_query(v_org, p_table_name := 'currencies', p_action := 'DELETE')) = 1, 'exactly one DELETE row for currencies';
  select * into r from audit_log_query(v_org, p_table_name := 'currencies', p_action := 'DELETE') limit 1;
  assert r.before_data is not null and r.after_data is null, 'a DELETE row should carry before_data and null after_data';

  select * into r from audit_log_query(v_org, p_table_name := 'currencies', p_action := 'INSERT') limit 1;
  assert r.before_data is null and r.after_data is not null, 'an INSERT row should carry null before_data and real after_data';

  -- =========================================================================
  -- 4) filter by actor
  -- =========================================================================
  assert (select count(*) from audit_log_query(v_org, p_user_id := v_owner)) = v_total, 'every row in this test was done by the owner';
  select * into r from audit_log_query(v_org, p_table_name := 'accounts', p_action := 'UPDATE') limit 1;
  assert r.user_email = 'owner@audit.test', 'actor email should be joined in correctly';

  -- =========================================================================
  -- 5) date-range filter
  -- =========================================================================
  assert (select count(*) from audit_log_query(v_org, p_from := now() + interval '1 hour')) = 0, 'a from-the-future filter should match nothing';
  assert (select count(*) from audit_log_query(v_org, p_to := now() - interval '1 hour')) = 0, 'a to-the-past filter should match nothing';
  assert (select count(*) from audit_log_query(v_org, p_from := now() - interval '1 minute', p_to := now() + interval '1 minute')) = v_total, 'a wide-enough window should match everything';

  -- =========================================================================
  -- 6) pagination
  -- =========================================================================
  assert (select count(*) from audit_log_query(v_org, p_limit := 2)) = 2, 'limit should cap the page size';
  assert (select count(*) from audit_log_query(v_org, p_limit := 1000)) <= 200, 'limit should be hard-capped at 200 regardless of what is requested';

  -- =========================================================================
  -- 7) helper dropdowns
  -- =========================================================================
  assert exists (select 1 from audit_log_table_names(v_org) where table_name = 'accounts'), 'accounts should appear in the table-name helper';
  assert exists (select 1 from audit_log_actors(v_org) where user_email = 'owner@audit.test'), 'owner should appear in the actors helper';

  -- =========================================================================
  -- 8) permission gating — the seeded viewer role has audit.read by
  --    default and CAN read; a custom role with zero granted permissions
  --    cannot (system roles are protected from having permissions stripped
  --    directly, so a fresh custom role is the clean way to test "no
  --    audit.read at all" rather than mutating the seeded viewer role)
  -- =========================================================================
  select id into v_viewer_role from roles where org_id = v_org and code = 'viewer';
  insert into memberships (org_id, user_id, role_id) values (v_org, 'f4000000-0000-0000-0004-000000000002', v_viewer_role);
  perform set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0004-000000000002', true);
  assert (select count(*) from audit_log_query(v_org)) >= 1, 'the seeded viewer role has audit.read and should be able to query';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  declare v_no_access_role uuid;
  begin
    insert into roles (org_id, code, name_ar, is_system) values (v_org, 'no_access', 'بلا صلاحيات', false) returning id into v_no_access_role;
    update memberships set role_id = v_no_access_role
      where org_id = v_org and user_id = 'f4000000-0000-0000-0004-000000000002';
  end;
  perform set_config('request.jwt.claim.sub', 'f4000000-0000-0000-0004-000000000002', true);
  begin
    perform audit_log_query(v_org);
    raise exception 'TEST FAIL: queried the audit log without audit.read';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  raise notice 'AUDIT LOG UI OK';
end $$;

rollback;
