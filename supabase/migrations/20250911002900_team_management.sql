-- ============================================================================
-- Rotopa · Module 00 (continued) — team management: members, roles, invitations
--
-- The RBAC MODEL already existed in full since module 00 (org-scoped roles,
-- a real permission catalog with 35 real keys across every module,
-- role_permissions as a flexible many-to-many, memberships.is_active
-- already checked by both app.is_member()/app.has_permission()) — checked
-- this directly before writing anything here. What was actually missing was
-- 100% a web surface for it, not schema. This migration adds exactly the
-- two things genuinely missing at the DB level: an invitation flow (so an
-- owner can add someone who doesn't have a Supabase account yet, without
-- ever needing the service-role key in the browser), and a guard so a
-- careless "roles.write" holder can't edit or delete the three seeded
-- system roles (owner/accountant/viewer) out from under themselves.
--
-- Inviting a not-yet-registered person deliberately does NOT use
-- supabase.auth.admin.* (that needs the service_role key, which must never
-- reach client code). Instead: an invitation row waits for a matching email
-- to sign up through the app's own existing Login/Onboarding flow, at which
-- point a trigger on auth.users converts it into a real membership
-- automatically — the same "trigger on auth.users" pattern Supabase itself
-- documents for profile-on-signup, just repurposed for membership-on-signup.
-- If the invited email already has a Supabase account (from a previous
-- signup, even for a different org), invite_member() skips the waiting
-- step and creates the membership immediately.
-- ============================================================================

create table membership_invitations (
  id                uuid primary key default extensions.gen_random_uuid(),
  org_id            uuid not null references organizations(id) on delete cascade,
  email             citext not null,
  role_id           uuid not null references roles(id) on delete restrict,
  default_branch_id uuid references branches(id) on delete set null,
  status            text not null default 'pending' check (status in ('pending','accepted','cancelled')),
  invited_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  accepted_at       timestamptz,
  cancelled_at      timestamptz
);
-- only one live invitation per (org, email) at a time — inviting again just
-- updates it (see invite_member()'s ON CONFLICT below)
create unique index membership_invitations_pending_unique on membership_invitations (org_id, email) where status = 'pending';
create index on membership_invitations (org_id, status);

alter table membership_invitations enable row level security;
create policy membership_invitation_all on membership_invitations for all
  using (app.has_permission(org_id, 'members.write'))
  with check (app.has_permission(org_id, 'members.write'));

-- ---------------------------------------------------------------------------
-- Auto-accept: when a person with a pending invitation actually signs up,
-- turn it into a real membership immediately — no separate "accept" click,
-- no admin action needed on the inviter's side.
-- ---------------------------------------------------------------------------
create or replace function app.tg_accept_pending_invitations()
returns trigger language plpgsql security definer set search_path = public, app as $$
declare inv record;
begin
  for inv in
    select * from membership_invitations
    where status = 'pending' and email = new.email::extensions.citext
  loop
    insert into memberships (org_id, user_id, role_id, default_branch_id, is_owner)
    values (inv.org_id, new.id, inv.role_id, inv.default_branch_id, false)
    on conflict (org_id, user_id) do nothing;
    update membership_invitations set status = 'accepted', accepted_at = now() where id = inv.id;
  end loop;
  return new;
end;
$$;
create trigger accept_pending_invitations
  after insert on auth.users
  for each row execute function app.tg_accept_pending_invitations();

-- ---------------------------------------------------------------------------
-- Protect the 3 seeded system roles (owner/accountant/viewer) from being
-- edited or deleted by anyone with plain 'roles.write' — otherwise someone
-- could strip their own 'owner' role's permissions and lock themselves out
-- with no way back in short of direct DB access.
-- ---------------------------------------------------------------------------
create or replace function app.tg_protect_system_role()
returns trigger language plpgsql as $$
begin
  if old.is_system then
    raise exception 'system role "%" cannot be modified or deleted', old.code using errcode = '23514';
  end if;
  if TG_OP = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger protect_system_role before update or delete on roles
  for each row execute function app.tg_protect_system_role();

-- create_organization() seeds the 3 system roles' permissions itself right
-- after creating them, which would otherwise trip this same guard — it
-- brackets that seeding with app.skip_role_guard so the check below only
-- ever fires for someone editing an ALREADY-seeded system role afterwards.
create or replace function app.tg_protect_system_role_permissions()
returns trigger language plpgsql as $$
declare v_system boolean; v_row role_permissions;
begin
  if current_setting('app.skip_role_guard', true) = 'on' then
    return coalesce(new, old);
  end if;
  v_row := coalesce(new, old);
  select is_system into v_system from roles where id = v_row.role_id;
  if v_system then
    raise exception 'system role permissions cannot be modified directly' using errcode = '23514';
  end if;
  return v_row;
end;
$$;
create trigger protect_system_role_permissions before insert or delete on role_permissions
  for each row execute function app.tg_protect_system_role_permissions();

-- ---------------------------------------------------------------------------
-- Read helpers — expose just enough of auth.users (which regular clients
-- can never query directly) to show a real team roster.
-- ---------------------------------------------------------------------------
create or replace function org_members(p_org uuid)
returns table (
  membership_id uuid, user_id uuid, email text, role_id uuid, role_code text, role_name text,
  is_owner boolean, is_active boolean, default_branch_id uuid, branch_name text, created_at timestamptz
)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_member(p_org) then raise exception 'not authorized' using errcode = '42501'; end if;
  return query
    select m.id, m.user_id, u.email::text, m.role_id, r.code, r.name_ar, m.is_owner, m.is_active,
           m.default_branch_id, b.name_ar, m.created_at
    from memberships m
    join auth.users u on u.id = m.user_id
    join roles r on r.id = m.role_id
    left join branches b on b.id = m.default_branch_id
    where m.org_id = p_org
    order by m.created_at;
end;
$$;

create or replace function org_pending_invitations(p_org uuid)
returns table (
  id uuid, email text, role_id uuid, role_name text,
  default_branch_id uuid, branch_name text, invited_by_email text, created_at timestamptz
)
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_permission(p_org, 'members.write');
  return query
    select i.id, i.email::text, i.role_id, r.name_ar, i.default_branch_id, b.name_ar,
           u.email::text, i.created_at
    from membership_invitations i
    join roles r on r.id = i.role_id
    left join branches b on b.id = i.default_branch_id
    left join auth.users u on u.id = i.invited_by
    where i.org_id = p_org and i.status = 'pending'
    order by i.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function invite_member(
  p_org uuid, p_email text, p_role_id uuid, p_default_branch_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_email extensions.citext := trim(p_email);
  v_existing_user uuid;
  v_role_org uuid;
  v_id uuid;
begin
  perform app.require_permission(p_org, 'members.write');

  if v_email is null or v_email = '' then raise exception 'email is required' using errcode = '23514'; end if;

  select org_id into v_role_org from roles where id = p_role_id;
  if v_role_org is distinct from p_org then
    raise exception 'role does not belong to this organization' using errcode = '23503';
  end if;

  select id into v_existing_user from auth.users where email::extensions.citext = v_email limit 1;

  if v_existing_user is not null then
    if exists (select 1 from memberships where org_id = p_org and user_id = v_existing_user) then
      raise exception 'this person is already a member of this organization' using errcode = '23505';
    end if;
    insert into memberships (org_id, user_id, role_id, default_branch_id, is_owner)
    values (p_org, v_existing_user, p_role_id, p_default_branch_id, false)
    returning id into v_id;
    return v_id;
  end if;

  insert into membership_invitations (org_id, email, role_id, default_branch_id, invited_by)
  values (p_org, v_email, p_role_id, p_default_branch_id, auth.uid())
  on conflict (org_id, email) where status = 'pending'
    do update set role_id = excluded.role_id, default_branch_id = excluded.default_branch_id
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function cancel_invitation(p_invitation_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_org uuid;
begin
  select org_id into v_org from membership_invitations where id = p_invitation_id and status = 'pending';
  if v_org is null then raise exception 'pending invitation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(v_org, 'members.write');

  update membership_invitations set status = 'cancelled', cancelled_at = now() where id = p_invitation_id;
  return p_invitation_id;
end;
$$;

-- shared by the three membership setters below
create or replace function app.assert_not_last_active_owner(p_membership_id uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare m memberships%rowtype; v_other_owners int;
begin
  select * into m from memberships where id = p_membership_id;
  if m.is_owner and m.is_active then
    select count(*) into v_other_owners from memberships
      where org_id = m.org_id and is_owner and is_active and id <> m.id;
    if v_other_owners = 0 then
      raise exception 'cannot change this member — they are the organization''s only remaining active owner' using errcode = '23514';
    end if;
  end if;
end;
$$;

create or replace function set_membership_role(p_membership_id uuid, p_role_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare m memberships%rowtype; v_role_org uuid;
begin
  select * into m from memberships where id = p_membership_id for update;
  if not found then raise exception 'membership not found' using errcode = 'P0002'; end if;
  perform app.require_permission(m.org_id, 'members.write');

  select org_id into v_role_org from roles where id = p_role_id;
  if v_role_org is distinct from m.org_id then raise exception 'role does not belong to this organization' using errcode = '23503'; end if;

  update memberships set role_id = p_role_id where id = p_membership_id;
  return p_membership_id;
end;
$$;

create or replace function set_membership_branch(p_membership_id uuid, p_default_branch_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare m memberships%rowtype; v_branch_org uuid;
begin
  select * into m from memberships where id = p_membership_id for update;
  if not found then raise exception 'membership not found' using errcode = 'P0002'; end if;
  perform app.require_permission(m.org_id, 'members.write');

  if p_default_branch_id is not null then
    select org_id into v_branch_org from branches where id = p_default_branch_id;
    if v_branch_org is distinct from m.org_id then raise exception 'branch does not belong to this organization' using errcode = '23503'; end if;
  end if;

  update memberships set default_branch_id = p_default_branch_id where id = p_membership_id;
  return p_membership_id;
end;
$$;

create or replace function set_membership_active(p_membership_id uuid, p_is_active boolean)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare m memberships%rowtype;
begin
  select * into m from memberships where id = p_membership_id for update;
  if not found then raise exception 'membership not found' using errcode = 'P0002'; end if;
  perform app.require_permission(m.org_id, 'members.write');

  if not p_is_active then perform app.assert_not_last_active_owner(p_membership_id); end if;

  update memberships set is_active = p_is_active where id = p_membership_id;
  return p_membership_id;
end;
$$;

create or replace function remove_membership(p_membership_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare m memberships%rowtype;
begin
  select * into m from memberships where id = p_membership_id for update;
  if not found then raise exception 'membership not found' using errcode = 'P0002'; end if;
  perform app.require_permission(m.org_id, 'members.write');

  perform app.assert_not_last_active_owner(p_membership_id);

  delete from memberships where id = p_membership_id;
  return p_membership_id;
end;
$$;

revoke all on function invite_member(uuid,text,uuid,uuid) from public, anon;
revoke all on function cancel_invitation(uuid) from public, anon;
revoke all on function set_membership_role(uuid,uuid) from public, anon;
revoke all on function set_membership_branch(uuid,uuid) from public, anon;
revoke all on function set_membership_active(uuid,boolean) from public, anon;
revoke all on function remove_membership(uuid) from public, anon;
revoke all on function org_members(uuid) from public, anon;
revoke all on function org_pending_invitations(uuid) from public, anon;
grant execute on function invite_member(uuid,text,uuid,uuid) to authenticated;
grant execute on function cancel_invitation(uuid) to authenticated;
grant execute on function set_membership_role(uuid,uuid) to authenticated;
grant execute on function set_membership_branch(uuid,uuid) to authenticated;
grant execute on function set_membership_active(uuid,boolean) to authenticated;
grant execute on function remove_membership(uuid) to authenticated;
grant execute on function org_members(uuid) to authenticated;
grant execute on function org_pending_invitations(uuid) to authenticated;
