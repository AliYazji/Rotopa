-- ============================================================================
-- Rotopa · Core Stabilization Phase 0 (2/3) — reject unimplemented sector
-- templates instead of silently seeding the restaurant/hotel chart.
--
-- 20250911004000_sector_templates.sql introduced organizations.sector with
-- a check constraint listing all 9 planned sectors, but only 2 of them
-- (restaurant_hotel, manufacturing) have a real app.seed_coa_<sector>()
-- template. create_organization() dispatched on p_sector with a plain
-- `else app.seed_default_chart_of_accounts(...)` — so p_sector='pharmacy'
-- (or any other not-yet-built sector) passed the check constraint fine and
-- silently got the restaurant/hotel chart, with organizations.sector still
-- correctly recording 'pharmacy'. That's a real trap: a pharmacy org would
-- look correctly tagged while actually running on the wrong chart of
-- accounts, with nothing in the UI or API surfacing the mismatch.
--
-- Fix: create_organization() now validates p_sector against the small set
-- of sectors that actually HAVE a template before doing anything else — no
-- org, currency, or account row is ever created for an unimplemented
-- sector. This is a body-only redefinition of the same 6-parameter
-- signature introduced in 20250911004000 (no drop needed — the parameter
-- list itself isn't changing, only the validation inside).
--
-- The other 7 sector names stay in the check constraint and in the web
-- Onboarding sector picker (shown disabled, "قريباً") — this migration
-- only stops the database from pretending one of them is ready.
-- ============================================================================

create or replace function create_organization(
  p_code text,
  p_name_ar text,
  p_base_currency_code text default 'NIS',
  p_base_currency_name_ar text default 'شيكل',
  p_fiscal_year_start_month int default 1,
  p_sector text default 'restaurant_hotel'
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_org uuid;
  v_cur uuid;
  v_role_owner uuid;
  v_role_acct  uuid;
  v_role_view  uuid;
  k text;
begin
  if auth.uid() is null then
    raise exception 'must be signed in to create an organization' using errcode = '42501';
  end if;

  -- only sectors with a real app.seed_coa_<sector>() template are accepted;
  -- everything else in organizations.sector's check constraint is a named,
  -- planned-but-not-built slot — no silent fallback to another sector's chart
  if coalesce(p_sector, 'restaurant_hotel') not in ('restaurant_hotel', 'manufacturing') then
    raise exception 'sector template is not implemented yet: %', p_sector using errcode = '22023';
  end if;

  insert into organizations (code, name_ar, fiscal_year_start_month, sector)
  values (p_code, p_name_ar, p_fiscal_year_start_month, coalesce(p_sector, 'restaurant_hotel'))
  returning id into v_org;

  insert into currencies (org_id, code, name_ar, is_base, decimal_places)
  values (v_org, p_base_currency_code, p_base_currency_name_ar, true, 2)
  returning id into v_cur;

  update organizations set base_currency_id = v_cur where id = v_org;

  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', true, 'rate', 0.16));

  -- dispatch to the sector's own chart-of-accounts template — both branches
  -- are now guaranteed real templates, the validation above already
  -- rejected anything else
  if p_sector = 'manufacturing' then
    perform app.seed_coa_manufacturing(v_org);
  else
    perform app.seed_default_chart_of_accounts(v_org);
  end if;

  -- roles
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'owner',      'مالك',   true) returning id into v_role_owner;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'accountant', 'محاسب',  true) returning id into v_role_acct;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'viewer',     'مطّلع',  true) returning id into v_role_view;

  perform set_config('app.skip_role_guard', 'on', true);
  insert into role_permissions (role_id, permission_key)
    select v_role_owner, key from permissions;
  insert into role_permissions (role_id, permission_key)
    select v_role_acct, key from permissions
    where key not in ('org.manage','roles.write','members.write');
  insert into role_permissions (role_id, permission_key) values
    (v_role_view, 'audit.read'), (v_role_view, 'reports.view');
  perform set_config('app.skip_role_guard', 'off', true);

  insert into memberships (org_id, user_id, role_id, is_owner)
  values (v_org, auth.uid(), v_role_owner, true);

  perform create_fiscal_year(v_org, extract(year from now())::int);

  return v_org;
end;
$$;

comment on column organizations.sector is
  'Picks which app.seed_coa_<sector>() chart-of-accounts template create_organization() seeds. Only restaurant_hotel and manufacturing have real templates so far — create_organization() rejects every other value outright (no silent fallback to another sector''s chart).';

-- Incidental hardening found while touching this function: 20250911004000
-- dropped the old 5-param create_organization() and created a new 6-param
-- one to add p_sector — but a freshly-created function's EXECUTE privilege
-- defaults to PUBLIC in Postgres, and the old explicit `revoke all ... from
-- public, anon` (20250911000700_seed_and_bootstrap.sql) only ever applied
-- to the now-dropped 5-param signature. Every other write-RPC in this
-- codebase explicitly revokes public/anon and grants only authenticated;
-- this restores that same convention for the current signature. Not
-- separately exploitable today (the function's own `auth.uid() is null`
-- check still blocks a genuinely unauthenticated call), but leaving a
-- write RPC on the default PUBLIC grant is inconsistent with how every
-- other one in this project is locked down.
revoke all on function create_organization(text, text, text, text, int, text) from public, anon;
grant execute on function create_organization(text, text, text, text, int, text) to authenticated;
