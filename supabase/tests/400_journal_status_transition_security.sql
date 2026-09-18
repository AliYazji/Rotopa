-- Regression coverage for 20250911004600_journal_status_transition_security.sql.
--
-- Before this fix, `je_write` was one FOR ALL policy gated only on
-- gl.create, with no awareness of `status` — a member holding gl.create
-- alone could directly UPDATE journal_entries to fake a draft->posted or
-- posted->void transition, skipping gl.post/gl.void entirely and (for
-- posted->void) leaving reversed_by NULL with no real reversing entry
-- ever created. This test drives every scenario through a REAL limited
-- member (a custom 'clerk' role holding gl.create only, membership
-- inserted directly — no gl.post, no gl.void) to prove direct SQL
-- attempts are blocked by the database itself, not just the UI.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('fc000000-0000-0000-0012-000000000001', 'owner@jesecurity.test'),
  ('fc000000-0000-0000-0012-000000000002', 'clerk@jesecurity.test');

-- owner builds the org and a deliberately limited role
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0012-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('JESECORG', 'مؤسسة اختبار أمان القيود')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_clerk_role uuid;
begin
  insert into roles (org_id, code, name_ar, is_system) values (v_org, 'clerk', 'كاتب قيود محدود', false) returning id into v_clerk_role;
  insert into role_permissions (role_id, permission_key) values (v_clerk_role, 'gl.create');
  -- deliberately NOT gl.post, NOT gl.void
  insert into memberships (org_id, user_id, role_id) values (v_org, 'fc000000-0000-0000-0012-000000000002', v_clerk_role);
end $$;

-- =============================================================================
-- as the limited clerk (gl.create only): create/edit/delete a draft works,
-- every direct attempt to move status works around post_journal_entry()/
-- void_journal_entry() must fail
-- =============================================================================
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0012-000000000002', true);
set local role authenticated;

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_rev uuid;
  v_cur uuid;
  v_draft uuid;
  v_caught boolean;
  v_rows int;
  v_status text;
begin
  select id into v_cash from accounts where org_id = v_org and code = '11101';
  select id into v_rev  from accounts where org_id = v_org and code = '61101';
  v_cur := (select base_currency_id from organizations where id = v_org);

  -- =========================================================================
  -- 1) the clerk (gl.create only) can create a draft
  -- =========================================================================
  v_draft := create_journal_entry(v_org, current_date, 'مسودة الكاتب',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 50, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 50, 'currency_id', v_cur)
    ));
  assert (select status from journal_entries where id = v_draft) = 'draft', 'a fresh entry should be a draft';

  -- =========================================================================
  -- 2) the clerk can edit the draft's description and lines directly —
  --    exactly what JournalDetail.tsx's saveDraft() does (status untouched)
  -- =========================================================================
  update journal_entries set description = 'مسودة معدّلة' where id = v_draft;
  assert (select description from journal_entries where id = v_draft) = 'مسودة معدّلة', 'editing a draft''s description directly should still work';

  delete from journal_lines where entry_id = v_draft;
  insert into journal_lines (entry_id, line_no, account_id, debit, credit, currency_id, rate)
  values (v_draft, 1, v_cash, 75, 0, v_cur, 1), (v_draft, 2, v_rev, 0, 75, v_cur, 1);
  assert (select count(*) from journal_lines where entry_id = v_draft) = 2, 'editing a draft''s lines directly should still work';

  -- =========================================================================
  -- 3) the clerk cannot fake draft -> posted with a direct UPDATE
  -- =========================================================================
  v_caught := false;
  begin
    update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_draft;
  exception when sqlstate '42501' then v_caught := true;
  end;
  assert v_caught, 'a direct UPDATE to status=posted should be rejected by RLS (sqlstate 42501)';
  assert (select status from journal_entries where id = v_draft) = 'draft', 'the entry should still be a draft after the rejected attempt';

  -- =========================================================================
  -- 4) the clerk cannot fake draft -> void with a direct UPDATE either
  -- =========================================================================
  v_caught := false;
  begin
    update journal_entries set status = 'void' where id = v_draft;
  exception when sqlstate '42501' then v_caught := true;
  end;
  assert v_caught, 'a direct UPDATE to status=void on a draft should be rejected by RLS (sqlstate 42501)';
  assert (select status from journal_entries where id = v_draft) = 'draft', 'the entry should still be a draft after the rejected attempt';

  -- =========================================================================
  -- 6) the clerk cannot post via the RPC either (no gl.post)
  -- =========================================================================
  v_caught := false;
  begin
    perform post_journal_entry(v_draft);
  exception when sqlstate '42501' then v_caught := true;
  end;
  assert v_caught, 'post_journal_entry() should reject a caller without gl.post (sqlstate 42501)';
  assert (select status from journal_entries where id = v_draft) = 'draft', 'the entry should still be a draft';

  raise notice 'JOURNAL STATUS SECURITY (CLERK, PART 1) OK';
end $$;

-- =============================================================================
-- back as the owner: post a real entry via RPC (so a genuine 'posted' row
-- exists), hand back to the clerk to prove a posted row is unreachable
-- =============================================================================
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0012-000000000001', true);
set local role authenticated;

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_rev uuid;
  v_cur uuid;
  v_posted uuid;
begin
  select id into v_cash from accounts where org_id = v_org and code = '11101';
  select id into v_rev  from accounts where org_id = v_org and code = '61101';
  v_cur := (select base_currency_id from organizations where id = v_org);

  v_posted := create_journal_entry(v_org, current_date, 'قيد الملك المرحّل',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 200, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 200, 'currency_id', v_cur)
    ));
  perform post_journal_entry(v_posted);
  assert (select status from journal_entries where id = v_posted) = 'posted', 'the owner should be able to post via the RPC';
  perform set_config('t.posted_entry', v_posted::text, true);
end $$;

select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0012-000000000002', true);
set local role authenticated;

do $$
declare
  v_posted uuid := current_setting('t.posted_entry')::uuid;
  v_rows int;
  v_caught boolean;
begin
  -- =========================================================================
  -- 5) the clerk cannot fake posted -> void with a direct UPDATE: the OLD
  --    row is status='posted', which the USING clause never matches, so
  --    RLS filters the row out before the update touches it at all — a
  --    silent 0-row UPDATE, not an exception (same class of RLS-blocks-
  --    silently behavior already established for cash_shifts in this
  --    project), which is why this is checked by row-count / unchanged
  --    status rather than an expected exception
  -- =========================================================================
  update journal_entries set status = 'void' where id = v_posted;
  get diagnostics v_rows = row_count;
  assert v_rows = 0, 'a direct UPDATE to void a posted entry should affect 0 rows (RLS filters it out on the OLD row), got ' || v_rows;
  assert (select status from journal_entries where id = v_posted) = 'posted', 'the entry should still be posted after the rejected attempt';
  assert (select reversed_by from journal_entries where id = v_posted) is null, 'the entry should have no reversed_by since no legitimate void happened';

  -- =========================================================================
  -- 7) the clerk cannot void via the RPC either (no gl.void)
  -- =========================================================================
  v_caught := false;
  begin
    perform void_journal_entry(v_posted, current_date, 'محاولة إلغاء بلا صلاحية');
  exception when sqlstate '42501' then v_caught := true;
  end;
  assert v_caught, 'void_journal_entry() should reject a caller without gl.void (sqlstate 42501)';
  assert (select status from journal_entries where id = v_posted) = 'posted', 'the entry should still be posted';

  -- =========================================================================
  -- 10) direct DELETE of a posted entry is rejected too
  -- =========================================================================
  delete from journal_entries where id = v_posted;
  get diagnostics v_rows = row_count;
  assert v_rows = 0, 'a direct DELETE of a posted entry should affect 0 rows, got ' || v_rows;
  assert exists (select 1 from journal_entries where id = v_posted), 'the posted entry should still exist';

  raise notice 'JOURNAL STATUS SECURITY (CLERK, PART 2) OK';
end $$;

-- =============================================================================
-- back as the owner (fully authorized): posting and voiding via RPC still
-- works end to end, with a real, correctly-linked reversal — and deleting
-- a draft directly is still allowed
-- =============================================================================
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0012-000000000001', true);
set local role authenticated;

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_posted uuid := current_setting('t.posted_entry')::uuid;
  v_cash uuid; v_rev uuid;
  v_cur uuid;
  v_reversal uuid;
  v_draft2 uuid;
  v_rows int;
begin
  select id into v_cash from accounts where org_id = v_org and code = '11101';
  select id into v_rev  from accounts where org_id = v_org and code = '61101';
  v_cur := (select base_currency_id from organizations where id = v_org);

  -- =========================================================================
  -- 8) an authorized user (owner) can post and void via RPC
  -- =========================================================================
  v_reversal := void_journal_entry(v_posted, current_date, 'إلغاء مخوّل');
  assert (select status from journal_entries where id = v_posted) = 'void', 'the owner-authorized void should succeed';
  assert (select status from journal_entries where id = v_reversal) = 'posted', 'the reversal entry should be posted';

  -- =========================================================================
  -- 9) the void created a REAL, correctly-linked, balanced reversal — the
  --    exact invariant the vulnerability could have silently broken
  -- =========================================================================
  assert (select reversed_by from journal_entries where id = v_posted) = v_reversal, 'reversed_by should point at the real reversal entry';
  assert (select void_of from journal_entries where id = v_reversal) = v_posted, 'the reversal''s void_of should point back at the original';
  assert (select sum(debit) from journal_lines where entry_id = v_reversal) = 200
     and (select sum(credit) from journal_lines where entry_id = v_reversal) = 200,
    'the reversal should carry the same 200/200 balanced amounts, swapped';
  assert account_balance(v_cash, null) = 0,
    'the posted entry and its authorized reversal should net to exactly 0 on account_balance() (the drafts never counted) — confirms this security fix composes correctly with the reporting fix';

  -- =========================================================================
  -- 10 (cont.) deleting a genuine draft directly is still allowed
  -- =========================================================================
  v_draft2 := create_journal_entry(v_org, current_date, 'مسودة للحذف',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 10, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 10, 'currency_id', v_cur)
    ));
  delete from journal_entries where id = v_draft2;
  get diagnostics v_rows = row_count;
  assert v_rows = 1, 'deleting a genuine draft directly should still succeed, got ' || v_rows || ' rows affected';
  assert not exists (select 1 from journal_entries where id = v_draft2), 'the deleted draft should be gone';
  assert not exists (select 1 from journal_lines where entry_id = v_draft2), 'its lines should be gone too (cascade)';

  raise notice 'JOURNAL STATUS SECURITY (OWNER) OK';
end $$;

rollback;
