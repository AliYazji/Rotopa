-- ============================================================================
-- Rotopa · Module 00 (continued) — audit log read surface for a web UI
--
-- `audit_log` + `app.tg_audit()` (attached to every real table already) have
-- existed since module 00, and `audit_select` RLS already gates direct
-- reads behind `audit.read` — checked directly before writing anything
-- here. The gap was purely a web surface: no filtering/pagination-friendly
-- read path, and no way to show WHO made a change (`auth.users.email` is
-- never visible to a direct client query, same reason org_members() and
-- fiscal_period_closure_log() each needed their own small read RPC).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Main query: filterable, paginated, joined to the actor's email. Returns
-- the matching page PLUS the total matching count (window function) so the
-- web UI can page without a second round trip.
-- ---------------------------------------------------------------------------
create or replace function audit_log_query(
  p_org uuid,
  p_table_name text default null,
  p_action text default null,
  p_user_id uuid default null,
  p_record_id text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit int default 50,
  p_offset int default 0
)
returns table (
  id bigint, user_id uuid, user_email text, action text, table_name text,
  record_id text, before_data jsonb, after_data jsonb, at timestamptz, total_count bigint
)
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_permission(p_org, 'audit.read');

  return query
    select l.id, l.user_id, u.email::text, l.action, l.table_name, l.record_id,
           l.before_data, l.after_data, l.at,
           count(*) over() as total_count
    from audit_log l
    left join auth.users u on u.id = l.user_id
    where l.org_id = p_org
      and (p_table_name is null or l.table_name = p_table_name)
      and (p_action is null or l.action = p_action)
      and (p_user_id is null or l.user_id = p_user_id)
      and (p_record_id is null or l.record_id = p_record_id)
      and (p_from is null or l.at >= p_from)
      and (p_to is null or l.at <= p_to)
    order by l.at desc, l.id desc
    limit least(coalesce(p_limit, 50), 200)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- Filter-dropdown helpers — cheap aggregates so the UI only offers tables/
-- actors that actually have entries for this org, instead of a static list.
-- ---------------------------------------------------------------------------
create or replace function audit_log_table_names(p_org uuid)
returns table (table_name text, entry_count bigint)
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_permission(p_org, 'audit.read');
  return query
    select l.table_name, count(*) from audit_log l
    where l.org_id = p_org group by l.table_name order by l.table_name;
end;
$$;

create or replace function audit_log_actors(p_org uuid)
returns table (user_id uuid, user_email text)
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_permission(p_org, 'audit.read');
  return query
    select distinct l.user_id, u.email::text
    from audit_log l
    left join auth.users u on u.id = l.user_id
    where l.org_id = p_org and l.user_id is not null
    order by 2;
end;
$$;

revoke all on function audit_log_query(uuid,text,text,uuid,text,timestamptz,timestamptz,int,int) from public, anon;
revoke all on function audit_log_table_names(uuid) from public, anon;
revoke all on function audit_log_actors(uuid) from public, anon;
grant execute on function audit_log_query(uuid,text,text,uuid,text,timestamptz,timestamptz,int,int) to authenticated;
grant execute on function audit_log_table_names(uuid) to authenticated;
grant execute on function audit_log_actors(uuid) to authenticated;
