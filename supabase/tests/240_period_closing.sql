-- Fiscal period/year closing workflow: chronological close order, reverse-
-- chronological reopen order, year-level master lock, mandatory reopen
-- reason, permission gating, and the closure log.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f3000000-0000-0000-0003-000000000001','owner@close.test'),
  ('f3000000-0000-0000-0003-000000000002','viewer@close.test');

select set_config('request.jwt.claim.sub','f3000000-0000-0000-0003-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('CLOSEORG','مؤسسة اختبار الإقفال','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_year uuid;
  v_viewer_role uuid;
  p uuid[]; -- 12 period ids, ordered by start_date
  v_d date;
  v_cash uuid; v_sales uuid; v_base uuid; v_parent uuid;
  r record;
  i int;
begin
  select id into v_year from fiscal_years where org_id = v_org;
  select array_agg(id order by start_date) into p from fiscal_periods where fiscal_year_id = v_year;
  assert array_length(p, 1) = 12, 'a fresh org should have exactly 12 periods';

  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','صندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','مبيعات',v_parent,true,'credit') returning id into v_sales;
  select base_currency_id into v_base from organizations where id = v_org;

  select id into v_viewer_role from roles where org_id = v_org and code = 'viewer';

  -- =========================================================================
  -- 1) close in chronological order; out-of-order close is rejected
  -- =========================================================================
  perform close_fiscal_period(p[1], 'إقفال شهري روتيني');
  assert (select status from fiscal_periods where id = p[1]) = 'closed', 'period 1 should be closed';

  begin
    perform close_fiscal_period(p[3]);
    raise exception 'TEST FAIL: closed period 3 while period 2 is still open';
  exception when sqlstate '23514' then null;
  end;

  -- closing an already-closed period is rejected
  begin
    perform close_fiscal_period(p[1]);
    raise exception 'TEST FAIL: closed an already-closed period';
  exception when sqlstate '23514' then null;
  end;

  perform close_fiscal_period(p[2]);
  perform close_fiscal_period(p[3]);
  assert (select count(*) from fiscal_periods where id = any(p[1:3]) and status = 'closed') = 3, 'periods 1-3 should all be closed';

  -- =========================================================================
  -- 2) posting into a closed period is rejected with the existing guard
  -- =========================================================================
  select start_date into v_d from fiscal_periods where id = p[1];
  begin
    perform create_journal_entry(v_org, v_d, 'في فترة مقفلة',
      jsonb_build_array(jsonb_build_object('account_id', v_cash, 'debit', 10, 'currency_id', v_base),
                         jsonb_build_object('account_id', v_sales, 'credit', 10, 'currency_id', v_base)));
    -- errcode '99001' is a custom code that will never collide with the
    -- real closed-period guard's own default P0001 (RAISE EXCEPTION with
    -- no USING ERRCODE) — using the SAME default code here as the guard
    -- would silently pass this test whether the guard fired or not
    raise exception 'TEST FAIL: posted into a closed period' using errcode = '99001';
  exception when sqlstate 'P0001' then null;
  end;

  -- =========================================================================
  -- 3) reopen requires a reason, must be reverse-chronological, and only a
  --    closed period can be reopened
  -- =========================================================================
  begin
    perform reopen_fiscal_period(p[3], null);
    raise exception 'TEST FAIL: reopened without a reason';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform reopen_fiscal_period(p[3], '   ');
    raise exception 'TEST FAIL: reopened with a blank reason';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform reopen_fiscal_period(p[4], 'محاولة خاطئة');
    raise exception 'TEST FAIL: reopened a period that was never closed';
  exception when sqlstate '23514' then null;
  end;

  -- period 1 (earliest closed) cannot reopen while period 3 (later) is still closed
  begin
    perform reopen_fiscal_period(p[1], 'محاولة بترتيب خاطئ');
    raise exception 'TEST FAIL: reopened period 1 while a later period (3) is still closed';
  exception when sqlstate '23514' then null;
  end;

  -- period 3 (most recently closed) reopens fine
  perform reopen_fiscal_period(p[3], 'تصحيح قيد فات');
  assert (select status from fiscal_periods where id = p[3]) = 'open', 'period 3 should reopen';
  assert (select closed_at from fiscal_periods where id = p[3]) is null, 'reopened period should clear closed_at';

  -- now period 2 can reopen (no later closed period left)
  perform reopen_fiscal_period(p[2], 'تصحيح قيد فات');
  assert (select status from fiscal_periods where id = p[2]) = 'open', 'period 2 should reopen';

  -- =========================================================================
  -- 4) closing the fiscal year requires every period closed first
  -- =========================================================================
  begin
    perform close_fiscal_year(v_year);
    raise exception 'TEST FAIL: closed the fiscal year with open periods remaining';
  exception when sqlstate '23514' then null;
  end;

  -- re-close 2 and 3, then close the remaining 4..12 in order
  perform close_fiscal_period(p[2]);
  perform close_fiscal_period(p[3]);
  for i in 4..12 loop
    perform close_fiscal_period(p[i]);
  end loop;
  assert (select count(*) from fiscal_periods where fiscal_year_id = v_year and status = 'closed') = 12, 'all 12 periods should be closed';

  perform close_fiscal_year(v_year, 'إقفال سنوي نهائي');
  assert (select status from fiscal_years where id = v_year) = 'closed', 'fiscal year should be closed';

  -- =========================================================================
  -- 5) a closed year is a master lock: no posting at all, and a period
  --    cannot reopen without reopening the year first
  -- =========================================================================
  select start_date into v_d from fiscal_periods where id = p[5];
  begin
    perform create_journal_entry(v_org, v_d, 'بعد إقفال السنة',
      jsonb_build_array(jsonb_build_object('account_id', v_cash, 'debit', 5, 'currency_id', v_base),
                         jsonb_build_object('account_id', v_sales, 'credit', 5, 'currency_id', v_base)));
    -- see the same-shaped block above: distinct errcode so this can never
    -- collide with the guard's own default P0001
    raise exception 'TEST FAIL: posted after the fiscal year was closed' using errcode = '99001';
  exception when sqlstate 'P0001' then null;
  end;

  begin
    perform reopen_fiscal_period(p[12], 'محاولة قبل فتح السنة');
    raise exception 'TEST FAIL: reopened a period while the fiscal year is still closed';
  exception when sqlstate '23514' then null;
  end;

  begin
    perform reopen_fiscal_year(v_year, null);
    raise exception 'TEST FAIL: reopened the fiscal year without a reason';
  exception when sqlstate '23514' then null;
  end;

  perform reopen_fiscal_year(v_year, 'مراجعة إضافية مطلوبة من الإدارة');
  assert (select status from fiscal_years where id = v_year) = 'open', 'fiscal year should reopen';

  -- most-recently-closed period (12) can now reopen
  perform reopen_fiscal_period(p[12], 'مراجعة إضافية مطلوبة من الإدارة');
  assert (select status from fiscal_periods where id = p[12]) = 'open', 'period 12 should reopen';

  -- =========================================================================
  -- 6) permission gating — a viewer cannot close/reopen anything
  -- =========================================================================
  insert into memberships (org_id, user_id, role_id) values (v_org, 'f3000000-0000-0000-0003-000000000002', v_viewer_role);
  perform set_config('request.jwt.claim.sub', 'f3000000-0000-0000-0003-000000000002', true);
  begin
    perform close_fiscal_period(p[11]);
    raise exception 'TEST FAIL: a viewer closed a fiscal period';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claim.sub', 'f3000000-0000-0000-0003-000000000001', true);

  -- =========================================================================
  -- 7) closure log records every action with a real actor and reason
  -- =========================================================================
  assert (select count(*) from fiscal_period_closure_log(v_org)) >= 10, 'closure log should have an entry per close/reopen action taken above';
  select * into r from fiscal_period_closure_log(v_org) order by done_at desc limit 1;
  assert r.action = 'reopen', 'most recent closure-log entry should be the last reopen';
  assert r.done_by_email = 'owner@close.test', 'closure log should record the real actor email';

  raise notice 'PERIOD CLOSING OK';
end $$;

rollback;
