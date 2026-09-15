-- Team management: inviting existing/not-yet-registered users, membership
-- role/branch/active edits, the last-active-owner guard, and system-role
-- protection triggers.
\set ON_ERROR_STOP on
begin;

-- every auth.users row needed for a person who is NOT the live session's
-- current identity is inserted up front, as the connecting (superuser) role
-- -- once we "set local role authenticated" below, that role has no insert
-- grant on auth.users (matching real Supabase: only GoTrue/service_role can
-- create auth users), same restriction every other test file works within.
insert into auth.users (id, email) values
  ('e2000000-0000-0000-0002-000000000001','owner@team.test'),
  ('e2000000-0000-0000-0002-000000000099','already@team.test'),
  ('e2000000-0000-0000-0002-000000000003','other@org.test');

select set_config('request.jwt.claim.sub','e2000000-0000-0000-0002-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('TEAMORG','مؤسسة اختبار الفريق','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_acct_role uuid;
  v_viewer_role uuid;
  v_branch uuid;
  v_inv_id uuid;
  v_existing_user uuid := 'e2000000-0000-0000-0002-000000000099';
  v_existing_membership uuid;
begin
  select id into v_acct_role from roles where org_id = v_org and code = 'accountant';
  select id into v_viewer_role from roles where org_id = v_org and code = 'viewer';
  insert into branches (org_id, code, name_ar) values (v_org, 'B1', 'الفرع الرئيسي') returning id into v_branch;

  -- =========================================================================
  -- 1) inviting an email with no Supabase account yet queues an invitation
  -- =========================================================================
  v_inv_id := invite_member(v_org, 'newhire@team.test', v_acct_role, v_branch);
  assert (select status from membership_invitations where id = v_inv_id) = 'pending', 'a fresh invite should be pending';
  assert (select count(*) from org_pending_invitations(v_org)) = 1, 'pending invitation should be listed';

  -- inviting the same email again updates the existing pending row instead of duplicating
  perform invite_member(v_org, 'newhire@team.test', v_viewer_role, null);
  assert (select count(*) from membership_invitations where org_id = v_org and email = 'newhire@team.test') = 1,
    'a second invite to the same pending email should update, not duplicate';
  assert (select role_id from membership_invitations where id = v_inv_id) = v_viewer_role, 'update should change the queued role';

  -- =========================================================================
  -- 2) inviting an email that already has a Supabase account joins immediately
  -- =========================================================================
  perform invite_member(v_org, 'already@team.test', v_acct_role, null);
  select id into v_existing_membership from memberships where org_id = v_org and user_id = v_existing_user;
  assert v_existing_membership is not null, 'inviting an already-registered email should create a membership immediately';
  assert not exists (select 1 from membership_invitations where org_id = v_org and email = 'already@team.test' and status = 'pending'),
    'no pending invitation should be left behind for an already-registered email';

  -- re-inviting someone already a member should fail
  begin
    perform invite_member(v_org, 'already@team.test', v_viewer_role, null);
    raise exception 'TEST FAIL: invited someone who is already a member';
  exception when sqlstate '23505' then null;
  end;

  -- =========================================================================
  -- 3) cancelling a pending invitation
  -- =========================================================================
  declare v_cancel_id uuid;
  begin
    v_cancel_id := invite_member(v_org, 'nevershows@team.test', v_viewer_role, null);
    perform cancel_invitation(v_cancel_id);
    assert (select status from membership_invitations where id = v_cancel_id) = 'cancelled', 'cancelled invitation should be marked cancelled';
  end;
end $$;

-- simulate the queued 'newhire@team.test' actually signing up: this must
-- happen as the connecting role (auth.users insert), not 'authenticated'
reset role;
insert into auth.users (id, email) values ('e2000000-0000-0000-0002-000000000002', 'newhire@team.test');
set local role authenticated;

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_owner uuid := 'e2000000-0000-0000-0002-000000000001';
  v_viewer_role uuid;
  v_acct_role uuid;
  v_branch uuid;
  v_existing_membership uuid;
  v_membership_id uuid;
begin
  select id into v_viewer_role from roles where org_id = v_org and code = 'viewer';
  select id into v_acct_role from roles where org_id = v_org and code = 'accountant';
  select id into v_branch from branches where org_id = v_org and code = 'B1';
  select id into v_existing_membership from memberships where org_id = v_org and user_id = 'e2000000-0000-0000-0002-000000000099';

  -- =========================================================================
  -- signup with the matching email should have auto-accepted the invitation
  -- =========================================================================
  assert (select status from membership_invitations where org_id = v_org and email = 'newhire@team.test') = 'accepted',
    'invitation should auto-accept on matching signup';
  assert exists (
    select 1 from memberships where org_id = v_org and user_id = 'e2000000-0000-0000-0002-000000000002' and role_id = v_viewer_role
  ), 'signup should create a real membership with the queued role';
  assert (select count(*) from org_pending_invitations(v_org)) = 0, 'no pending invitations should remain (newhire accepted, nevershows cancelled)';

  -- =========================================================================
  -- 4) editing role / branch / active status on a membership
  -- =========================================================================
  perform set_membership_role(v_existing_membership, v_viewer_role);
  assert (select role_id from memberships where id = v_existing_membership) = v_viewer_role, 'role should update';

  perform set_membership_branch(v_existing_membership, v_branch);
  assert (select default_branch_id from memberships where id = v_existing_membership) = v_branch, 'branch should update';

  perform set_membership_active(v_existing_membership, false);
  assert (select is_active from memberships where id = v_existing_membership) = false, 'membership should deactivate';
  perform set_membership_active(v_existing_membership, true);
  assert (select is_active from memberships where id = v_existing_membership) = true, 'membership should reactivate';

  -- =========================================================================
  -- 5) the sole remaining active owner cannot be deactivated or removed
  -- =========================================================================
  select id into v_membership_id from memberships where org_id = v_org and user_id = v_owner;
  begin
    perform set_membership_active(v_membership_id, false);
    raise exception 'TEST FAIL: deactivated the only remaining active owner';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform remove_membership(v_membership_id);
    raise exception 'TEST FAIL: removed the only remaining active owner';
  exception when sqlstate '23514' then null;
  end;

  -- promote a second membership to owner, then the original owner CAN be
  -- deactivated since they are no longer the last one. Do this acting as
  -- the OTHER owner, not as the owner being deactivated -- deactivating
  -- yourself correctly revokes your own permission to act any further
  -- (is_active is enforced live), which would otherwise strand this test.
  update memberships set is_owner = true where id = v_existing_membership;
  perform set_config('request.jwt.claim.sub', 'e2000000-0000-0000-0002-000000000099', true);
  perform set_membership_active(v_membership_id, false);
  assert (select is_active from memberships where id = v_membership_id) = false, 'owner should be deactivatable once a second active owner exists';
  perform set_membership_active(v_membership_id, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  -- =========================================================================
  -- 6) system roles (owner/accountant/viewer) cannot be edited or deleted
  -- =========================================================================
  begin
    update roles set name_ar = 'shouldnt work' where id = v_acct_role;
    raise exception 'TEST FAIL: modified a system role';
  exception when sqlstate '23514' then null;
  end;
  begin
    delete from roles where id = v_viewer_role;
    raise exception 'TEST FAIL: deleted a system role';
  exception when sqlstate '23514' then null;
  end;
  begin
    insert into role_permissions (role_id, permission_key) values (v_viewer_role, 'org.manage');
    raise exception 'TEST FAIL: added a permission directly to a system role';
  exception when sqlstate '23514' then null;
  end;
  begin
    delete from role_permissions where role_id = v_acct_role and permission_key = 'reports.view';
    raise exception 'TEST FAIL: removed a permission directly from a system role';
  exception when sqlstate '23514' then null;
  end;

  -- =========================================================================
  -- 7) a custom (non-system) role can be freely created and edited
  -- =========================================================================
  declare v_custom_role uuid;
  begin
    insert into roles (org_id, code, name_ar, is_system) values (v_org, 'cashier', 'أمين صندوق', false) returning id into v_custom_role;
    insert into role_permissions (role_id, permission_key) values (v_custom_role, 'reports.view');
    update roles set name_ar = 'أمين صندوق رئيسي' where id = v_custom_role;
    delete from role_permissions where role_id = v_custom_role and permission_key = 'reports.view';
    delete from roles where id = v_custom_role;
    assert not exists (select 1 from roles where id = v_custom_role), 'a custom role should be fully editable and deletable';
  end;

  -- =========================================================================
  -- 8) org_members() lists everyone with their role/branch/status
  -- =========================================================================
  assert (select count(*) from org_members(v_org)) = 3, 'org_members should list the owner + the two joined members';

  raise notice 'TEAM MANAGEMENT OK';
end $$;

-- =========================================================================
-- 9) a branch belonging to a different org cannot be assigned to a
--    membership here ('other@org.test' was already created up front)
-- =========================================================================
do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_existing_membership uuid;
  v_other_org uuid;
  v_other_branch uuid;
  v_owner_sub text := current_setting('request.jwt.claim.sub');
begin
  select id into v_existing_membership from memberships where org_id = v_org and user_id = 'e2000000-0000-0000-0002-000000000099';

  perform set_config('request.jwt.claim.sub', 'e2000000-0000-0000-0002-000000000003', true);
  v_other_org := create_organization('OTHERORG2','مؤسسة أخرى','NIS','شيكل',1);
  insert into branches (org_id, code, name_ar) values (v_other_org, 'OB1', 'فرع آخر') returning id into v_other_branch;

  perform set_config('request.jwt.claim.sub', v_owner_sub, true);
  begin
    perform set_membership_branch(v_existing_membership, v_other_branch);
    raise exception 'TEST FAIL: assigned a branch from a different organization';
  exception when sqlstate '23503' then null;
  end;

  raise notice 'TEAM MANAGEMENT — CROSS-ORG GUARD OK';
end $$;

rollback;
