-- ============================================================================
-- Rotopa · Module 02 (continued) — fiscal period/year closing workflow
--
-- `fiscal_periods.status`/`fiscal_years.status` and `app.open_period_for()`'s
-- "reject posting into anything but an open period" check have existed
-- since module 02 — checked directly before writing this. What was missing
-- was the WORKFLOW around actually flipping that status: no RPC ever set it
-- to 'closed', so in practice every period has sat open forever. This adds
-- the two things genuinely missing: authorized close/reopen RPCs with real
-- accounting-order guards (close oldest-open-first, reopen newest-closed-
-- first, and a period's year must be reopened before any of its periods
-- can be), and a permanent, reason-carrying closure log distinct from the
-- generic audit_log (audit_log records the raw before/after row; this
-- records the human "why" for each close/reopen decision, the same
-- "dedicated permanent event-log table" pattern already used for
-- fixed_asset_depreciation_runs and reservation_nights).
--
-- Deliberately NOT in scope here (documented, not silently skipped): this
-- project still has no periodic P&L-closing-to-retained-earnings mechanism
-- (see docs/data-model.md module 08 — balance_sheet()'s synthetic UNCLOSED
-- row). Locking a period only blocks further POSTINGS into it; it does not
-- generate any closing journal entry. Those are two different features.
-- ============================================================================

create table fiscal_period_closures (
  id             bigint generated always as identity primary key,
  org_id         uuid not null references organizations(id) on delete cascade,
  fiscal_year_id uuid not null references fiscal_years(id) on delete cascade,
  period_id      uuid references fiscal_periods(id) on delete cascade,  -- null = a year-level close/reopen
  action         text not null check (action in ('close','reopen')),
  reason         text,
  done_by        uuid references auth.users(id),
  done_at        timestamptz not null default now()
);
create index on fiscal_period_closures (org_id, done_at desc);
create index on fiscal_period_closures (fiscal_year_id);

alter table fiscal_period_closures enable row level security;
create policy fpc_select on fiscal_period_closures for select using (app.is_member(org_id));
create policy fpc_write  on fiscal_period_closures for all
  using (app.has_permission(org_id, 'periods.write'))
  with check (app.has_permission(org_id, 'periods.write'));

-- ---------------------------------------------------------------------------
-- A closed fiscal YEAR is a master lock: postings are still gated by the
-- PERIOD's own status day-to-day, but this closes the loophole of reopening
-- one period without going through the year first (see reopen_fiscal_period
-- below, which refuses to run while the year is closed).
-- ---------------------------------------------------------------------------
create or replace function app.open_period_for(p_org uuid, p_date date)
returns uuid language plpgsql stable as $$
declare
  v_id uuid;
  v_status text;
  v_year_status text;
begin
  select p.id, p.status, y.status into v_id, v_status, v_year_status
  from fiscal_periods p
  join fiscal_years y on y.id = p.fiscal_year_id
  where p.org_id = p_org and p_date between p.start_date and p.end_date;

  if v_id is null then
    raise exception 'no fiscal period defined for % (org %)', p_date, p_org
      using errcode = 'P0001';
  end if;
  if v_year_status <> 'open' then
    raise exception 'fiscal year for % is closed, not open', p_date
      using errcode = 'P0001';
  end if;
  if v_status <> 'open' then
    raise exception 'fiscal period for % is %, not open', p_date, v_status
      using errcode = 'P0001';
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- close_fiscal_period — must close in chronological order: an earlier
-- period left open would otherwise let someone backdate a posting into it
-- after a "later" period already looks closed, which is exactly the gap a
-- period-close workflow exists to prevent.
-- ---------------------------------------------------------------------------
create or replace function close_fiscal_period(p_period_id uuid, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare p fiscal_periods%rowtype;
begin
  select * into p from fiscal_periods where id = p_period_id for update;
  if not found then raise exception 'fiscal period not found' using errcode = 'P0002'; end if;
  perform app.require_permission(p.org_id, 'periods.write');

  if p.status <> 'open' then
    raise exception 'only an open period can be closed' using errcode = '23514';
  end if;

  if exists (
    select 1 from fiscal_periods
    where org_id = p.org_id and status = 'open' and start_date < p.start_date
  ) then
    raise exception 'cannot close this period while an earlier period is still open — close periods in chronological order' using errcode = '23514';
  end if;

  update fiscal_periods set status = 'closed', closed_at = now(), closed_by = auth.uid() where id = p_period_id;
  insert into fiscal_period_closures (org_id, fiscal_year_id, period_id, action, reason, done_by)
  values (p.org_id, p.fiscal_year_id, p.id, 'close', p_reason, auth.uid());

  return p_period_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- reopen_fiscal_period — the more dangerous direction: requires a reason,
-- requires the year itself to already be open (a closed year is the master
-- lock — reopen the year first), and must reopen in REVERSE chronological
-- order (most-recently-closed first) so there's never a closed period
-- sitting chronologically behind an open one.
-- ---------------------------------------------------------------------------
create or replace function reopen_fiscal_period(p_period_id uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare p fiscal_periods%rowtype; v_year_status text;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'a reason is required to reopen a closed period' using errcode = '23514';
  end if;

  select * into p from fiscal_periods where id = p_period_id for update;
  if not found then raise exception 'fiscal period not found' using errcode = 'P0002'; end if;
  perform app.require_permission(p.org_id, 'periods.write');

  if p.status <> 'closed' then
    raise exception 'only a closed period can be reopened' using errcode = '23514';
  end if;

  select status into v_year_status from fiscal_years where id = p.fiscal_year_id;
  if v_year_status <> 'open' then
    raise exception 'the fiscal year is closed — reopen the year before reopening any of its periods' using errcode = '23514';
  end if;

  if exists (
    select 1 from fiscal_periods
    where org_id = p.org_id and status = 'closed' and start_date > p.start_date
  ) then
    raise exception 'cannot reopen this period while a later period is still closed — reopen periods in reverse chronological order' using errcode = '23514';
  end if;

  update fiscal_periods set status = 'open', closed_at = null, closed_by = null where id = p_period_id;
  insert into fiscal_period_closures (org_id, fiscal_year_id, period_id, action, reason, done_by)
  values (p.org_id, p.fiscal_year_id, p.id, 'reopen', p_reason, auth.uid());

  return p_period_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- close_fiscal_year — a deliberate, separate ceremony from closing the
-- last period: requires every period in the year to already be closed.
-- ---------------------------------------------------------------------------
create or replace function close_fiscal_year(p_fiscal_year_id uuid, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare y fiscal_years%rowtype; v_open_count int;
begin
  select * into y from fiscal_years where id = p_fiscal_year_id for update;
  if not found then raise exception 'fiscal year not found' using errcode = 'P0002'; end if;
  perform app.require_permission(y.org_id, 'periods.write');

  if y.status <> 'open' then
    raise exception 'only an open fiscal year can be closed' using errcode = '23514';
  end if;

  select count(*) into v_open_count from fiscal_periods where fiscal_year_id = y.id and status <> 'closed';
  if v_open_count > 0 then
    raise exception 'all % periods must be closed before closing the fiscal year (% still open)', 12, v_open_count using errcode = '23514';
  end if;

  update fiscal_years set status = 'closed' where id = p_fiscal_year_id;
  insert into fiscal_period_closures (org_id, fiscal_year_id, period_id, action, reason, done_by)
  values (y.org_id, y.id, null, 'close', p_reason, auth.uid());

  return p_fiscal_year_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- reopen_fiscal_year — requires a reason. Does NOT cascade-reopen any
-- period; each one still needs its own reopen_fiscal_period() call (its
-- own guard, its own reason, its own log row).
-- ---------------------------------------------------------------------------
create or replace function reopen_fiscal_year(p_fiscal_year_id uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare y fiscal_years%rowtype;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'a reason is required to reopen a closed fiscal year' using errcode = '23514';
  end if;

  select * into y from fiscal_years where id = p_fiscal_year_id for update;
  if not found then raise exception 'fiscal year not found' using errcode = 'P0002'; end if;
  perform app.require_permission(y.org_id, 'periods.write');

  if y.status <> 'closed' then
    raise exception 'only a closed fiscal year can be reopened' using errcode = '23514';
  end if;

  update fiscal_years set status = 'open' where id = p_fiscal_year_id;
  insert into fiscal_period_closures (org_id, fiscal_year_id, period_id, action, reason, done_by)
  values (y.org_id, y.id, null, 'reopen', p_reason, auth.uid());

  return p_fiscal_year_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Read helper — the closure log needs auth.users.email for "who", which a
-- direct client query can never see; fiscal_years/fiscal_periods themselves
-- are already directly readable by any member (existing fy_select/fp_select
-- policies), so no read RPC is needed for those.
-- ---------------------------------------------------------------------------
create or replace function fiscal_period_closure_log(p_org uuid)
returns table (
  id bigint, fiscal_year_code text, period_no smallint, action text,
  reason text, done_by_email text, done_at timestamptz
)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_member(p_org) then raise exception 'not authorized' using errcode = '42501'; end if;
  return query
    select c.id, y.code, p.period_no, c.action, c.reason, u.email::text, c.done_at
    from fiscal_period_closures c
    join fiscal_years y on y.id = c.fiscal_year_id
    left join fiscal_periods p on p.id = c.period_id
    left join auth.users u on u.id = c.done_by
    where c.org_id = p_org
    -- done_at is transaction-time (now()), constant across every closure
    -- issued in one transaction — id is the only true insertion-order tiebreaker
    order by c.done_at desc, c.id desc;
end;
$$;

revoke all on function close_fiscal_period(uuid,text) from public, anon;
revoke all on function reopen_fiscal_period(uuid,text) from public, anon;
revoke all on function close_fiscal_year(uuid,text) from public, anon;
revoke all on function reopen_fiscal_year(uuid,text) from public, anon;
revoke all on function fiscal_period_closure_log(uuid) from public, anon;
grant execute on function close_fiscal_period(uuid,text) to authenticated;
grant execute on function reopen_fiscal_period(uuid,text) to authenticated;
grant execute on function close_fiscal_year(uuid,text) to authenticated;
grant execute on function reopen_fiscal_year(uuid,text) to authenticated;
grant execute on function fiscal_period_closure_log(uuid) to authenticated;
