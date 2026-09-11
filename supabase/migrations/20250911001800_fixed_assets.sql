-- ============================================================================
-- Rotopa · Module 13 — Fixed assets
--
-- Unlike every prior document (journal/voucher/stock-move/sales/purchase
-- invoice), a fixed asset has NO draft phase. Registering one posts a real
-- acquisition entry (Dr asset account / Cr cash-or-payable) atomically —
-- there is no multi-line document to stage and edit before committing, just
-- one fact ("we now own this, it cost this much, starting this date").
-- Consequence, stated plainly: a fixed asset row is immutable from the
-- moment it's created — its financial fields can never be edited, and it
-- can never be deleted, matching the plan's own rule ("لا حذف فعلي"). The
-- only correction path is dispose() (even same-day, at zero proceeds) then
-- register a corrected replacement — which is also the textbook-correct
-- accounting treatment for "we registered this wrong": you record the
-- correction, you don't erase the mistake.
--
-- Two more events happen against an already-registered asset, each its own
-- posted entry:
--   * post_depreciation() — straight-line only for now. Dr depreciation
--     expense / Cr accumulated depreciation, capped so accumulated
--     depreciation can never exceed (cost - salvage_value). Each run is
--     its own row in fixed_asset_depreciation_runs (so journal_entries'
--     unique(org_id, source_type, source_id) has a fresh source_id every
--     time — an asset gets depreciated monthly, unlike acquisition/disposal
--     which each happen exactly once).
--   * dispose_fixed_asset() — the standard disposal entry: Dr accumulated
--     depreciation (clear it), Dr proceeds account (if any), Dr or Cr a
--     gain/loss account for the difference between proceeds and net book
--     value, Cr the asset account (clear the original cost).
-- ============================================================================

create table fixed_assets (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  code          text not null,
  name_ar       text not null,

  -- immutable from insert — see header comment
  asset_account_id             uuid not null references accounts(id) on delete restrict,
  accum_depreciation_account_id uuid not null references accounts(id) on delete restrict,
  acquisition_date  date not null,
  cost              numeric(19,4) not null check (cost > 0),
  salvage_value     numeric(19,4) not null default 0 check (salvage_value >= 0),
  useful_life_months int not null check (useful_life_months > 0),

  -- editable any time — cosmetic / administrative only
  depreciation_expense_account_id uuid not null references accounts(id) on delete restrict,
  notes         text not null default '',

  -- system-maintained by post_depreciation()/dispose_fixed_asset() only
  accumulated_depreciation numeric(19,4) not null default 0 check (accumulated_depreciation >= 0),
  last_depreciated_through date,
  status        text not null default 'active' check (status in ('active','disposed')),
  disposal_date     date,
  disposal_proceeds numeric(19,4),
  disposal_reason   text,
  acquisition_journal_entry_id uuid references journal_entries(id) on delete restrict,
  disposal_journal_entry_id    uuid references journal_entries(id) on delete restrict,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (org_id, code),
  constraint fa_salvage_not_over_cost check (salvage_value <= cost),
  constraint fa_accum_not_over_depreciable_base check (accumulated_depreciation <= cost - salvage_value),
  constraint fa_disposed_has_details check (
    status <> 'disposed' or (disposal_date is not null and disposal_journal_entry_id is not null)
  )
);
create index on fixed_assets (org_id, status);

-- Each depreciation run is its own row/document — an asset gets depreciated
-- monthly (or whenever run), unlike acquisition/disposal which each happen
-- once, so journal_entries' one-entry-per-source-document constraint needs
-- a fresh id every time. Permanent audit trail: never updated or deleted.
create table fixed_asset_depreciation_runs (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  asset_id      uuid not null references fixed_assets(id) on delete restrict,
  through_date  date not null,
  amount        numeric(19,4) not null check (amount > 0),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),

  unique (org_id, asset_id, through_date)
);
create index on fixed_asset_depreciation_runs (org_id, asset_id);

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create or replace function app.tg_fixed_asset_guard()
returns trigger language plpgsql as $$
begin
  if new.org_id <> old.org_id or new.code <> old.code
     or new.asset_account_id <> old.asset_account_id
     or new.accum_depreciation_account_id <> old.accum_depreciation_account_id
     or new.acquisition_date <> old.acquisition_date
     or new.cost <> old.cost or new.salvage_value <> old.salvage_value
     or new.useful_life_months <> old.useful_life_months then
    raise exception 'fixed asset % — these fields are permanent once registered (the acquisition entry already committed to them); dispose and re-register to correct a mistake', old.code
      using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger fixed_asset_guard before update on fixed_assets for each row execute function app.tg_fixed_asset_guard();

create trigger set_updated_at before update on fixed_assets for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on fixed_assets for each row execute function app.tg_audit();

-- Permanent once created — no draft phase to except, unlike every other
-- posted-document table's app.tg_block_delete_unless_draft().
create or replace function app.tg_block_delete_always()
returns trigger language plpgsql as $$
begin
  raise exception '% % is permanent and cannot be deleted', tg_table_name, old.id using errcode = '23514';
end;
$$;
create trigger block_delete_always before delete on fixed_assets for each row execute function app.tg_block_delete_always();
create trigger block_delete_always before delete on fixed_asset_depreciation_runs for each row execute function app.tg_block_delete_always();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function register_fixed_asset(
  p_org uuid, p_code text, p_name_ar text,
  p_asset_account_id uuid, p_accum_depreciation_account_id uuid, p_depreciation_expense_account_id uuid,
  p_acquisition_date date, p_cost numeric, p_salvage_value numeric, p_useful_life_months int,
  p_credit_account_id uuid,   -- cash/bank paid, or a payable account — a single plain account, no dealer tracking yet
  p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_asset uuid;
  v_entry uuid;
  v_period uuid;
  v_currency uuid;
begin
  perform app.require_permission(p_org, 'fixed_assets.write');
  perform app.require_permission(p_org, 'fixed_assets.post');

  insert into fixed_assets (org_id, code, name_ar, asset_account_id, accum_depreciation_account_id,
                             depreciation_expense_account_id, acquisition_date, cost, salvage_value,
                             useful_life_months, notes, created_by)
  values (p_org, p_code, p_name_ar, p_asset_account_id, p_accum_depreciation_account_id,
          p_depreciation_expense_account_id, p_acquisition_date, p_cost, coalesce(p_salvage_value, 0),
          p_useful_life_months, coalesce(p_notes, ''), auth.uid())
  returning id into v_asset;

  select base_currency_id into v_currency from organizations where id = p_org;
  v_period := app.open_period_for(p_org, p_acquisition_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, created_by)
  values (p_org, app.next_seq(p_org, 'journal'), p_acquisition_date, v_period,
          'تسجيل أصل ثابت: ' || p_name_ar, 'fixed_asset', v_asset, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  values (v_entry, 1, p_asset_account_id, 'تسجيل أصل ثابت: ' || p_name_ar, p_cost, 0, v_currency, 1),
         (v_entry, 2, p_credit_account_id, 'تسجيل أصل ثابت: ' || p_name_ar, 0, p_cost, v_currency, 1);

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update fixed_assets set acquisition_journal_entry_id = v_entry where id = v_asset;

  return v_asset;
end;
$$;

create or replace function post_depreciation(p_asset_id uuid, p_through_date date)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  a fixed_assets%rowtype;
  v_base_date date;
  v_monthly numeric(19,4);
  v_months int;
  v_remaining numeric(19,4);
  v_amount numeric(19,4);
  v_run uuid;
  v_entry uuid;
  v_period uuid;
  v_currency uuid;
begin
  select * into a from fixed_assets where id = p_asset_id for update;
  if not found then raise exception 'asset not found' using errcode = 'P0002'; end if;
  perform app.require_permission(a.org_id, 'fixed_assets.post');
  if a.status <> 'active' then raise exception 'only an active asset can be depreciated' using errcode = '23514'; end if;

  v_base_date := coalesce(a.last_depreciated_through, a.acquisition_date);
  if p_through_date <= v_base_date then
    raise exception 'through date must be after the last depreciation run (%)', v_base_date using errcode = '23514';
  end if;

  v_months := (date_part('year', age(p_through_date, v_base_date)) * 12
             + date_part('month', age(p_through_date, v_base_date)))::int;
  if v_months < 1 then
    raise exception 'less than a full month has elapsed since %', v_base_date using errcode = '23514';
  end if;

  v_monthly := round((a.cost - a.salvage_value) / a.useful_life_months, 4);
  v_remaining := (a.cost - a.salvage_value) - a.accumulated_depreciation;
  v_amount := least(v_monthly * v_months, v_remaining);
  if v_amount <= 0 then
    raise exception 'asset % is already fully depreciated', a.code using errcode = '23514';
  end if;

  insert into fixed_asset_depreciation_runs (org_id, asset_id, through_date, amount, created_by)
  values (a.org_id, a.id, p_through_date, v_amount, auth.uid())
  returning id into v_run;

  select base_currency_id into v_currency from organizations where id = a.org_id;
  v_period := app.open_period_for(a.org_id, p_through_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, created_by)
  values (a.org_id, app.next_seq(a.org_id, 'journal'), p_through_date, v_period,
          'إهلاك أصل ' || a.code || ' — ' || a.name_ar || ' حتى ' || p_through_date,
          'fixed_asset_depreciation', v_run, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  values (v_entry, 1, a.depreciation_expense_account_id, 'إهلاك ' || a.code, v_amount, 0, v_currency, 1),
         (v_entry, 2, a.accum_depreciation_account_id, 'إهلاك ' || a.code, 0, v_amount, v_currency, 1);

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update fixed_asset_depreciation_runs set journal_entry_id = v_entry where id = v_run;
  update fixed_assets set accumulated_depreciation = accumulated_depreciation + v_amount,
                           last_depreciated_through = p_through_date
    where id = p_asset_id;

  return v_entry;
end;
$$;

-- Convenience batch runner for a monthly close: depreciates every active
-- asset with something due, skipping (not failing) any with nothing due
-- yet or already fully depreciated — one asset's non-event shouldn't abort
-- the whole run.
create or replace function depreciate_all_assets(p_org uuid, p_through_date date)
returns table(asset_id uuid, journal_entry_id uuid, amount numeric)
language plpgsql security definer set search_path = public, app as $$
declare a record; v_entry uuid; v_amount numeric(19,4);
begin
  perform app.require_permission(p_org, 'fixed_assets.post');
  for a in select id from fixed_assets where org_id = p_org and status = 'active' order by code loop
    begin
      v_entry := post_depreciation(a.id, p_through_date);
    exception when sqlstate '23514' then
      continue;   -- nothing due for this asset this run
    end;
    select fadr.amount into v_amount from fixed_asset_depreciation_runs fadr where fadr.journal_entry_id = v_entry;
    asset_id := a.id;
    journal_entry_id := v_entry;
    amount := v_amount;
    return next;
  end loop;
end;
$$;

create or replace function dispose_fixed_asset(
  p_asset_id uuid, p_disposal_date date, p_proceeds numeric default 0,
  p_proceeds_account_id uuid default null, p_gain_loss_account_id uuid default null,
  p_reason text default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  a fixed_assets%rowtype;
  v_nbv numeric(19,4);
  v_gain numeric(19,4);
  v_entry uuid;
  v_period uuid;
  v_currency uuid;
  v_line_no int := 0;
  v_proceeds numeric(19,4) := coalesce(p_proceeds, 0);
begin
  select * into a from fixed_assets where id = p_asset_id for update;
  if not found then raise exception 'asset not found' using errcode = 'P0002'; end if;
  perform app.require_permission(a.org_id, 'fixed_assets.post');
  if a.status <> 'active' then raise exception 'only an active asset can be disposed' using errcode = '23514'; end if;
  if v_proceeds > 0 and p_proceeds_account_id is null then
    raise exception 'a proceeds account is required when proceeds > 0' using errcode = '23514';
  end if;

  v_nbv := a.cost - a.accumulated_depreciation;
  v_gain := v_proceeds - v_nbv;
  if v_gain <> 0 and p_gain_loss_account_id is null then
    raise exception 'a gain/loss account is required — proceeds (%) differ from net book value (%)', v_proceeds, v_nbv
      using errcode = '23514';
  end if;

  select base_currency_id into v_currency from organizations where id = a.org_id;
  v_period := app.open_period_for(a.org_id, p_disposal_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, created_by)
  values (a.org_id, app.next_seq(a.org_id, 'journal'), p_disposal_date, v_period,
          'استبعاد أصل ' || a.code || ' — ' || a.name_ar || coalesce(' — ' || p_reason, ''),
          'fixed_asset_disposal', a.id, auth.uid())
  returning id into v_entry;

  if a.accumulated_depreciation > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, a.accum_depreciation_account_id, 'استبعاد ' || a.code, a.accumulated_depreciation, 0, v_currency, 1);
  end if;
  if v_proceeds > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_proceeds_account_id, 'استبعاد ' || a.code, v_proceeds, 0, v_currency, 1);
  end if;
  if v_gain > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_gain_loss_account_id, 'ربح استبعاد ' || a.code, 0, v_gain, v_currency, 1);
  elsif v_gain < 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_gain_loss_account_id, 'خسارة استبعاد ' || a.code, -v_gain, 0, v_currency, 1);
  end if;
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  values (v_entry, v_line_no, a.asset_account_id, 'استبعاد ' || a.code, 0, a.cost, v_currency, 1);

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update fixed_assets set status = 'disposed', disposal_date = p_disposal_date, disposal_proceeds = v_proceeds,
                          disposal_reason = p_reason, disposal_journal_entry_id = v_entry
    where id = p_asset_id;

  return v_entry;
end;
$$;

revoke all on function register_fixed_asset(uuid,text,text,uuid,uuid,uuid,date,numeric,numeric,int,uuid,text) from public, anon;
revoke all on function post_depreciation(uuid,date) from public, anon;
revoke all on function depreciate_all_assets(uuid,date) from public, anon;
revoke all on function dispose_fixed_asset(uuid,date,numeric,uuid,uuid,text) from public, anon;
grant execute on function register_fixed_asset(uuid,text,text,uuid,uuid,uuid,date,numeric,numeric,int,uuid,text) to authenticated;
grant execute on function post_depreciation(uuid,date) to authenticated;
grant execute on function depreciate_all_assets(uuid,date) to authenticated;
grant execute on function dispose_fixed_asset(uuid,date,numeric,uuid,uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('fixed_assets.write', 'accounting', 'تسجيل أصل ثابت وتعديل بياناته الوصفية', false),
  ('fixed_assets.post',  'accounting', 'ترحيل الإهلاك واستبعاد الأصول الثابتة', true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('fixed_assets.write','fixed_assets.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('fixed_assets.write','fixed_assets.post') on conflict do nothing;

alter table fixed_assets                    enable row level security;
alter table fixed_asset_depreciation_runs   enable row level security;

create policy fixed_asset_select on fixed_assets for select using (app.is_member(org_id));
-- No INSERT policy: registration always goes through register_fixed_asset()
-- (SECURITY DEFINER), which guarantees the acquisition entry is posted in
-- the same transaction — a direct client INSERT could create an asset with
-- no matching GL entry at all. UPDATE stays open (gated by permission) only
-- for the cosmetic fields the guard trigger still allows. DELETE is left
-- permissive on purpose — without a policy, RLS would silently filter the
-- row out and DELETE would match zero rows with no error; WITH the policy,
-- the row is visible and block_delete_always's trigger fires and raises a
-- clear "this is permanent" exception instead of a confusing silent no-op.
create policy fixed_asset_update on fixed_assets for update
  using (app.has_permission(org_id, 'fixed_assets.write')) with check (app.has_permission(org_id, 'fixed_assets.write'));
create policy fixed_asset_delete on fixed_assets for delete using (app.has_permission(org_id, 'fixed_assets.write'));

create policy fixed_asset_depreciation_run_select on fixed_asset_depreciation_runs for select using (app.is_member(org_id));
-- No INSERT/UPDATE policy: a permanent audit trail written only by
-- post_depreciation(). DELETE stays permissive for the same reason as
-- above — so the guard trigger's clear error fires instead of a silent
-- zero-row no-op.
create policy fixed_asset_depreciation_run_delete on fixed_asset_depreciation_runs for delete using (app.is_member(org_id));
