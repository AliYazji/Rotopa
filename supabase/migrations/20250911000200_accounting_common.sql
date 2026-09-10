-- ============================================================================
-- Rotopa · Module 02 — Currencies & FX   +   fiscal calendar
-- Base-currency amounts are the single source of truth for the ledger.
-- Every foreign amount is stored together with the rate used to convert it,
-- so a report never has to guess a historical rate.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Money helper — one rounding rule for the whole system
-- ---------------------------------------------------------------------------
create or replace function app.round_money(p_amount numeric, p_org uuid default null)
returns numeric language sql immutable as $$
  select round(coalesce(p_amount, 0), 4);
$$;

-- ---------------------------------------------------------------------------
-- Currencies
-- ---------------------------------------------------------------------------
create table currencies (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  code          citext not null,                 -- ISO 4217 where possible: NIS, USD, JOD
  name_ar       text not null,
  name_en       text,
  symbol        text,
  minor_unit_ar text,                             -- أغورة / سنت / فلس
  decimal_places smallint not null default 2 check (decimal_places between 0 and 4),
  is_base       boolean not null default false,
  is_active     boolean not null default true,
  legacy_no     int,                              -- maps to Lockup 'Currancy' FieldNo
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);
create index on currencies (org_id);
-- exactly one base currency per org
create unique index currencies_one_base_uk on currencies (org_id) where is_base;

alter table organizations
  add constraint organizations_base_currency_fk
  foreign key (base_currency_id) references currencies(id)
  deferrable initially deferred;

-- ---------------------------------------------------------------------------
-- Exchange rates — value of 1 unit of `currency` expressed in the base currency
-- ---------------------------------------------------------------------------
create table exchange_rates (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  currency_id   uuid not null references currencies(id) on delete cascade,
  rate_date     date not null,
  rate          numeric(19,9) not null check (rate > 0),   -- mid / accounting rate
  buy_rate      numeric(19,9) check (buy_rate  > 0),
  sell_rate     numeric(19,9) check (sell_rate > 0),
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id),
  unique (org_id, currency_id, rate_date)
);
create index on exchange_rates (org_id, currency_id, rate_date desc);

-- Rate to use for a currency on a given date: the most recent rate on/before it.
-- Base currency is always 1. Falls back to the earliest known rate if the date
-- precedes all entries, so a conversion never returns NULL.
create or replace function fx_rate(p_currency_id uuid, p_date date)
returns numeric(19,9) language plpgsql stable as $$
declare
  v_is_base boolean;
  v_rate    numeric(19,9);
begin
  select is_base into v_is_base from currencies where id = p_currency_id;
  if v_is_base is null then
    raise exception 'unknown currency %', p_currency_id using errcode = '23503';
  end if;
  if v_is_base then
    return 1;
  end if;

  select rate into v_rate
  from exchange_rates
  where currency_id = p_currency_id and rate_date <= p_date
  order by rate_date desc
  limit 1;

  if v_rate is null then
    select rate into v_rate
    from exchange_rates
    where currency_id = p_currency_id
    order by rate_date asc
    limit 1;
  end if;

  if v_rate is null then
    raise exception 'no exchange rate for currency % on or before %', p_currency_id, p_date
      using errcode = 'P0001';
  end if;
  return v_rate;
end;
$$;

-- Convert a foreign amount to base currency using an explicit rate.
create or replace function to_base(p_amount numeric, p_rate numeric)
returns numeric language sql immutable as $$
  select round(coalesce(p_amount,0) * coalesce(p_rate,0), 4);
$$;

-- ---------------------------------------------------------------------------
-- Fiscal calendar — years and periods, with hard close
-- ---------------------------------------------------------------------------
create table fiscal_years (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,                       -- '2024'
  start_date  date not null,
  end_date    date not null,
  status      text not null default 'open' check (status in ('open','closed')),
  created_at  timestamptz not null default now(),
  unique (org_id, code),
  check (end_date > start_date)
);
create index on fiscal_years (org_id);

create table fiscal_periods (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  fiscal_year_id uuid not null references fiscal_years(id) on delete cascade,
  period_no     smallint not null check (period_no between 1 and 12),
  start_date    date not null,
  end_date      date not null,
  status        text not null default 'open' check (status in ('open','closed','locked')),
  closed_at     timestamptz,
  closed_by     uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  unique (org_id, fiscal_year_id, period_no),
  check (end_date >= start_date)
);
create index on fiscal_periods (org_id, start_date, end_date);
-- no two periods for the same org may overlap
alter table fiscal_periods
  add constraint fiscal_periods_no_overlap
  exclude using gist (org_id with =, daterange(start_date, end_date, '[]') with &&);

-- Resolve the period a date falls into; error if none / if it is not open.
create or replace function app.open_period_for(p_org uuid, p_date date)
returns uuid language plpgsql stable as $$
declare
  v_id uuid;
  v_status text;
begin
  select id, status into v_id, v_status
  from fiscal_periods
  where org_id = p_org and p_date between start_date and end_date;

  if v_id is null then
    raise exception 'no fiscal period defined for % (org %)', p_date, p_org
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
-- RLS
-- ---------------------------------------------------------------------------
alter table currencies      enable row level security;
alter table exchange_rates  enable row level security;
alter table fiscal_years    enable row level security;
alter table fiscal_periods  enable row level security;

create policy currency_select on currencies for select using (app.is_member(org_id));
create policy currency_write  on currencies for all
  using (app.has_permission(org_id, 'currencies.write'))
  with check (app.has_permission(org_id, 'currencies.write'));

create policy rate_select on exchange_rates for select using (app.is_member(org_id));
create policy rate_write  on exchange_rates for all
  using (app.has_permission(org_id, 'rates.write'))
  with check (app.has_permission(org_id, 'rates.write'));

create policy fy_select on fiscal_years for select using (app.is_member(org_id));
create policy fy_write  on fiscal_years for all
  using (app.has_permission(org_id, 'periods.write'))
  with check (app.has_permission(org_id, 'periods.write'));

create policy fp_select on fiscal_periods for select using (app.is_member(org_id));
create policy fp_write  on fiscal_periods for all
  using (app.has_permission(org_id, 'periods.write'))
  with check (app.has_permission(org_id, 'periods.write'));

create trigger set_updated_at before update on currencies for each row execute function app.tg_set_updated_at();

create trigger audit after insert or update or delete on currencies     for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on exchange_rates for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on fiscal_years   for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on fiscal_periods for each row execute function app.tg_audit();
