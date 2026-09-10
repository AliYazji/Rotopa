-- ============================================================================
-- Rotopa · Module 00 — Platform
-- Tenancy, identity, RBAC, lookups, settings, audit trail.
-- Every domain row in Rotopa belongs to exactly one organization and is
-- reachable only through an explicit membership + permission check (RLS).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------
create or replace function app.tg_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Organizations & branches
-- ---------------------------------------------------------------------------
create table organizations (
  id                  uuid primary key default extensions.gen_random_uuid(),
  code                citext not null unique,
  name_ar             text not null,
  name_en             text,
  -- base_currency_id is wired up in the currencies migration (deferred FK).
  base_currency_id    uuid,
  fiscal_year_start_month  smallint not null default 1
                        check (fiscal_year_start_month between 1 and 12),
  -- money is always rounded to this many places for this org.
  money_scale         smallint not null default 2 check (money_scale between 0 and 4),
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table branches (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on branches (org_id);

-- ---------------------------------------------------------------------------
-- Identity — one profile per auth user
-- ---------------------------------------------------------------------------
create table profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  phone       text,
  locale      text not null default 'ar',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create or replace function app.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  insert into public.profiles (user_id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (user_id) do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------------------
-- RBAC — permission catalog, roles per org, memberships
-- ---------------------------------------------------------------------------
create table permissions (
  key         text primary key,          -- e.g. 'accounts.write', 'gl.post'
  module      text not null,
  description_ar text not null,
  is_dangerous  boolean not null default false
);

create table roles (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  is_system   boolean not null default false,   -- seeded, cannot be deleted
  created_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on roles (org_id);

create table role_permissions (
  role_id       uuid not null references roles(id) on delete cascade,
  permission_key text not null references permissions(key) on delete cascade,
  primary key (role_id, permission_key)
);

create table memberships (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role_id     uuid not null references roles(id),
  is_owner    boolean not null default false,   -- owners bypass permission checks
  default_branch_id uuid references branches(id),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, user_id)
);
create index on memberships (user_id);
create index on memberships (org_id);
create index on memberships (role_id);

-- ---------------------------------------------------------------------------
-- Authorization helpers  (SECURITY DEFINER -> bypass RLS, no recursion)
-- ---------------------------------------------------------------------------
create or replace function app.org_ids()
returns setof uuid language sql stable security definer set search_path = public, app as $$
  select m.org_id
  from public.memberships m
  where m.user_id = auth.uid() and m.is_active;
$$;

create or replace function app.is_member(p_org uuid)
returns boolean language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.org_id = p_org and m.is_active
  );
$$;

create or replace function app.has_permission(p_org uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1
    from public.memberships m
    where m.user_id = auth.uid() and m.org_id = p_org and m.is_active
      and (
        m.is_owner
        or exists (
          select 1 from public.role_permissions rp
          where rp.role_id = m.role_id and rp.permission_key = p_perm
        )
      )
  );
$$;

-- Raises instead of returning false — use inside SECURITY DEFINER RPCs.
create or replace function app.require_permission(p_org uuid, p_perm text)
returns void language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.has_permission(p_org, p_perm) then
    raise exception 'not authorized: % on org %', p_perm, p_org
      using errcode = '42501';
  end if;
end;
$$;

-- RLS policies call these as the querying role, so `authenticated` must be able
-- to execute them (they are SECURITY DEFINER, so they still can't be abused).
revoke all on function app.org_ids(), app.is_member(uuid),
  app.has_permission(uuid, text), app.require_permission(uuid, text) from public;
grant usage on schema app to authenticated, service_role;
grant execute on function app.org_ids(), app.is_member(uuid),
  app.has_permission(uuid, text), app.require_permission(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Lookups  (replaces legacy Lockup_tb — one row per enumerated value)
-- ---------------------------------------------------------------------------
create table lookups (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid references organizations(id) on delete cascade,   -- null = system default
  category    text not null,               -- 'cheque_status', 'dealer_type', ...
  code        text not null,               -- stable machine value
  name_ar     text not null,
  name_en     text,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index lookups_scope_uk on lookups (coalesce(org_id, '00000000-0000-0000-0000-000000000000'), category, code);
create index on lookups (org_id, category);

-- ---------------------------------------------------------------------------
-- Org settings  (replaces legacy Logo_tb — typed key/value instead of 181 columns)
-- ---------------------------------------------------------------------------
create table org_settings (
  org_id      uuid not null references organizations(id) on delete cascade,
  key         text not null,
  value       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  primary key (org_id, key)
);

-- ---------------------------------------------------------------------------
-- Audit trail  (append-only; every domain table streams here via trigger)
-- ---------------------------------------------------------------------------
create table audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid,
  user_id     uuid,
  action      text not null,               -- INSERT | UPDATE | DELETE
  table_name  text not null,
  record_id   text,
  before_data jsonb,
  after_data  jsonb,
  at          timestamptz not null default now()
);
create index on audit_log (org_id, table_name, at desc);
create index on audit_log (org_id, at desc);

create or replace function app.tg_audit()
returns trigger language plpgsql security definer set search_path = public, app as $$
declare
  v_row jsonb := to_jsonb(coalesce(new, old));
begin
  insert into public.audit_log (org_id, user_id, action, table_name, record_id, before_data, after_data)
  values (
    nullif(v_row->>'org_id','')::uuid,
    auth.uid(),
    tg_op,
    tg_table_name,
    v_row->>'id',
    case when tg_op = 'INSERT' then null else to_jsonb(old) end,
    case when tg_op = 'DELETE' then null else to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table organizations   enable row level security;
alter table branches        enable row level security;
alter table profiles        enable row level security;
alter table permissions     enable row level security;
alter table roles           enable row level security;
alter table role_permissions enable row level security;
alter table memberships     enable row level security;
alter table lookups         enable row level security;
alter table org_settings    enable row level security;
alter table audit_log       enable row level security;

-- organizations: visible to members; only owners may change org-level config.
create policy org_select on organizations for select using (app.is_member(id));
create policy org_update on organizations for update using (app.has_permission(id, 'org.manage'))
  with check (app.has_permission(id, 'org.manage'));

-- branches
create policy branch_select on branches for select using (app.is_member(org_id));
create policy branch_write  on branches for all
  using (app.has_permission(org_id, 'branches.write'))
  with check (app.has_permission(org_id, 'branches.write'));

-- profiles: a user sees their own profile and profiles of co-members.
create policy profile_self on profiles for select using (
  user_id = auth.uid()
  or exists (
    select 1 from memberships m1
    join memberships m2 on m2.org_id = m1.org_id
    where m1.user_id = auth.uid() and m2.user_id = profiles.user_id
  )
);
create policy profile_update_self on profiles for update using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- permission catalog: readable by any authenticated user, immutable from the API.
create policy perm_select on permissions for select to authenticated using (true);

-- roles & role_permissions
create policy role_select on roles for select using (app.is_member(org_id));
create policy role_write  on roles for all
  using (app.has_permission(org_id, 'roles.write'))
  with check (app.has_permission(org_id, 'roles.write'));
create policy roleperm_select on role_permissions for select using (
  exists (select 1 from roles r where r.id = role_id and app.is_member(r.org_id))
);
create policy roleperm_write on role_permissions for all using (
  exists (select 1 from roles r where r.id = role_id and app.has_permission(r.org_id, 'roles.write'))
) with check (
  exists (select 1 from roles r where r.id = role_id and app.has_permission(r.org_id, 'roles.write'))
);

-- memberships
create policy membership_select on memberships for select using (
  user_id = auth.uid() or app.is_member(org_id)
);
create policy membership_write on memberships for all
  using (app.has_permission(org_id, 'members.write'))
  with check (app.has_permission(org_id, 'members.write'));

-- lookups: system defaults + own-org rows readable; writes need permission.
create policy lookup_select on lookups for select using (
  org_id is null or app.is_member(org_id)
);
create policy lookup_write on lookups for all
  using (org_id is not null and app.has_permission(org_id, 'lookups.write'))
  with check (org_id is not null and app.has_permission(org_id, 'lookups.write'));

-- org_settings
create policy settings_select on org_settings for select using (app.is_member(org_id));
create policy settings_write on org_settings for all
  using (app.has_permission(org_id, 'settings.write'))
  with check (app.has_permission(org_id, 'settings.write'));

-- audit_log: readable with permission, never writable from the API.
create policy audit_select on audit_log for select using (
  org_id is not null and app.has_permission(org_id, 'audit.read')
);

-- updated_at triggers
create trigger set_updated_at before update on organizations for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on branches      for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on profiles      for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on memberships   for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on lookups       for each row execute function app.tg_set_updated_at();

-- audit triggers
create trigger audit after insert or update or delete on organizations for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on branches      for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on roles         for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on memberships   for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on org_settings  for each row execute function app.tg_audit();
