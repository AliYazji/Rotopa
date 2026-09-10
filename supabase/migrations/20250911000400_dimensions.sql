-- ============================================================================
-- Rotopa · Module 03 — Accounting Dimensions
-- Optional analysis axes attached to each journal line: cost centre,
-- department, fund, project. Budgets are planned amounts per account/period.
-- ============================================================================

create table cost_centers (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  parent_id   uuid references cost_centers(id) on delete restrict,
  is_active   boolean not null default true,
  legacy_no   bigint,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on cost_centers (org_id);

create table departments (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  parent_id   uuid references departments(id) on delete restrict,
  manager_name text,
  is_active   boolean not null default true,
  legacy_no   bigint,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on departments (org_id);

create table funds (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  is_active   boolean not null default true,
  legacy_no   bigint,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on funds (org_id);

create table projects (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  department_id uuid references departments(id) on delete set null,
  fund_id     uuid references funds(id) on delete set null,
  start_date  date,
  end_date    date,
  status      text not null default 'active' check (status in ('planned','active','on_hold','closed')),
  is_active   boolean not null default true,
  legacy_no   bigint,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on projects (org_id);

-- ---------------------------------------------------------------------------
-- Budgets — planned amount per account per fiscal period
-- ---------------------------------------------------------------------------
create table budgets (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  code          text not null,
  name_ar       text not null,
  fiscal_year_id uuid not null references fiscal_years(id) on delete restrict,
  currency_id   uuid not null references currencies(id),
  status        text not null default 'draft' check (status in ('draft','approved','closed')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);
create index on budgets (org_id);

create table budget_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  budget_id     uuid not null references budgets(id) on delete cascade,
  account_id    uuid not null references accounts(id) on delete restrict,
  cost_center_id uuid references cost_centers(id) on delete restrict,
  period_no     smallint not null check (period_no between 1 and 12),
  amount        numeric(19,4) not null default 0,
  unique (budget_id, account_id, cost_center_id, period_no)
);
create index on budget_lines (budget_id);

-- ---------------------------------------------------------------------------
-- RLS  (one permission key covers all dimension master data)
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['cost_centers','departments','funds','projects','budgets'] loop
    execute format('alter table %I enable row level security', t);
    execute format($p$create policy %1$s_select on %1$s for select using (app.is_member(org_id))$p$, t);
    execute format($p$create policy %1$s_write on %1$s for all
        using (app.has_permission(org_id, 'dimensions.write'))
        with check (app.has_permission(org_id, 'dimensions.write'))$p$, t);
    execute format('create trigger set_updated_at before update on %I for each row execute function app.tg_set_updated_at()', t);
    execute format('create trigger audit after insert or update or delete on %I for each row execute function app.tg_audit()', t);
  end loop;
end $$;

alter table budget_lines enable row level security;
create policy budget_lines_select on budget_lines for select using (
  exists (select 1 from budgets b where b.id = budget_id and app.is_member(b.org_id))
);
create policy budget_lines_write on budget_lines for all using (
  exists (select 1 from budgets b where b.id = budget_id and app.has_permission(b.org_id, 'dimensions.write'))
) with check (
  exists (select 1 from budgets b where b.id = budget_id and app.has_permission(b.org_id, 'dimensions.write'))
);
