-- ============================================================================
-- Rotopa · Seed reference data + organization bootstrap
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Permission catalog
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('org.manage',       'platform',   'تعديل إعدادات المؤسسة',            true),
  ('branches.write',   'platform',   'إدارة الفروع',                     false),
  ('roles.write',      'platform',   'إدارة الأدوار والصلاحيات',         true),
  ('members.write',    'platform',   'إدارة المستخدمين والعضويات',       true),
  ('settings.write',   'platform',   'تعديل الإعدادات العامة',           false),
  ('lookups.write',    'platform',   'تعديل القوائم المرجعية',           false),
  ('audit.read',       'platform',   'الاطلاع على سجل التدقيق',          false),
  ('accounts.write',   'accounting', 'تعديل دليل الحسابات',              false),
  ('currencies.write', 'accounting', 'إدارة العملات',                    false),
  ('rates.write',      'accounting', 'إدخال أسعار الصرف',                false),
  ('periods.write',    'accounting', 'إدارة الفترات المحاسبية وإقفالها', true),
  ('dimensions.write', 'accounting', 'إدارة مراكز التكلفة والأقسام والموازنات', false),
  ('dealers.write',    'accounting', 'إدارة العملاء والموردين والموظفين', false),
  ('gl.create',        'accounting', 'إنشاء وتعديل قيود مسودة',          false),
  ('gl.post',          'accounting', 'ترحيل القيود',                     true),
  ('gl.void',          'accounting', 'إلغاء القيود المرحّلة',            true),
  ('reports.view',     'accounting', 'عرض التقارير المالية',             false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- System lookups (org_id = null — visible to every organization)
-- ---------------------------------------------------------------------------
insert into lookups (org_id, category, code, name_ar, name_en, sort_order) values
  (null, 'account_nature', 'debit',  'مدين',       'Debit',  1),
  (null, 'account_nature', 'credit', 'دائن',       'Credit', 2),
  (null, 'account_nature', 'both',   'مدين/دائن',  'Both',   3),

  (null, 'dealer_role', 'customer', 'زبون',  'Customer', 1),
  (null, 'dealer_role', 'supplier', 'مورد',  'Supplier', 2),
  (null, 'dealer_role', 'employee', 'موظف',  'Employee', 3),

  (null, 'journal_status', 'draft',  'مسودة',   'Draft',  1),
  (null, 'journal_status', 'posted', 'مرحّل',   'Posted', 2),
  (null, 'journal_status', 'void',   'ملغى',    'Void',   3),

  (null, 'cheque_status', 'in_hand',     'في الحافظة',      'In hand',       1),
  (null, 'cheque_status', 'deposited',   'تحت التحصيل',     'Deposited',     2),
  (null, 'cheque_status', 'cleared',     'محصّل',           'Cleared',       3),
  (null, 'cheque_status', 'bounced',     'مرتجع',           'Bounced',       4),
  (null, 'cheque_status', 'endorsed',    'مُجيّر',           'Endorsed',      5),
  (null, 'cheque_status', 'cancelled',   'ملغى',            'Cancelled',     6),

  (null, 'cashflow_class', 'cash',       'نقدي',      'Cash',       1),
  (null, 'cashflow_class', 'operating',  'تشغيلي',    'Operating',  2),
  (null, 'cashflow_class', 'investing',  'استثماري',  'Investing',  3),
  (null, 'cashflow_class', 'financing',  'تمويلي',    'Financing',  4)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- create_fiscal_year(org, calendar_year) — year + 12 monthly periods
-- ---------------------------------------------------------------------------
create or replace function create_fiscal_year(p_org uuid, p_year int)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_start_month smallint;
  v_fy_start date;
  v_fy_id uuid;
  i int;
  v_pstart date;
begin
  perform app.require_permission(p_org, 'periods.write');
  select fiscal_year_start_month into v_start_month from organizations where id = p_org;
  v_fy_start := make_date(p_year, v_start_month, 1);

  insert into fiscal_years (org_id, code, start_date, end_date)
  values (p_org, p_year::text, v_fy_start, (v_fy_start + interval '1 year' - interval '1 day')::date)
  returning id into v_fy_id;

  for i in 0..11 loop
    v_pstart := (v_fy_start + (i || ' month')::interval)::date;
    insert into fiscal_periods (org_id, fiscal_year_id, period_no, start_date, end_date)
    values (p_org, v_fy_id, i + 1, v_pstart, (v_pstart + interval '1 month' - interval '1 day')::date);
  end loop;

  return v_fy_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_organization(...) — the one call that stands up a tenant
-- Creates: org, base currency, default roles, owner membership,
--          current fiscal year with 12 periods.
-- ---------------------------------------------------------------------------
create or replace function create_organization(
  p_code text,
  p_name_ar text,
  p_base_currency_code text default 'NIS',
  p_base_currency_name_ar text default 'شيكل',
  p_fiscal_year_start_month int default 1
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

  insert into organizations (code, name_ar, fiscal_year_start_month)
  values (p_code, p_name_ar, p_fiscal_year_start_month)
  returning id into v_org;

  insert into currencies (org_id, code, name_ar, is_base, decimal_places)
  values (v_org, p_base_currency_code, p_base_currency_name_ar, true, 2)
  returning id into v_cur;

  update organizations set base_currency_id = v_cur where id = v_org;

  -- roles
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'owner',      'مالك',   true) returning id into v_role_owner;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'accountant', 'محاسب',  true) returning id into v_role_acct;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'viewer',     'مطّلع',  true) returning id into v_role_view;

  -- seeding the 3 fresh system roles' permissions is legitimate even though
  -- a later direct edit to a system role's permissions is not (see
  -- app.tg_protect_system_role_permissions in 20250911002900_team_management.sql)
  perform set_config('app.skip_role_guard', 'on', true);

  -- owner gets everything (also bypasses via is_owner, but be explicit)
  insert into role_permissions (role_id, permission_key)
    select v_role_owner, key from permissions;

  -- accountant: everything except the platform-danger keys
  insert into role_permissions (role_id, permission_key)
    select v_role_acct, key from permissions
    where key not in ('org.manage','roles.write','members.write');

  -- viewer: read-only
  insert into role_permissions (role_id, permission_key) values
    (v_role_view, 'audit.read'), (v_role_view, 'reports.view');

  perform set_config('app.skip_role_guard', 'off', true);

  -- creator becomes owner
  insert into memberships (org_id, user_id, role_id, is_owner)
  values (v_org, auth.uid(), v_role_owner, true);

  -- current fiscal year
  perform create_fiscal_year(v_org, extract(year from now())::int);

  return v_org;
end;
$$;

revoke all on function create_organization(text,text,text,text,int) from public, anon;
revoke all on function create_fiscal_year(uuid,int) from public, anon;
grant execute on function create_organization(text,text,text,text,int) to authenticated;
grant execute on function create_fiscal_year(uuid,int) to authenticated;
