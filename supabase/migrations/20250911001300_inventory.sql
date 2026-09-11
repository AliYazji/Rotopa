-- ============================================================================
-- Rotopa · Module 09 — Inventory
--
-- Costing is moving-weighted-average, matching the legacy system's own
-- avrg_price/average_price columns on ITEM_TB. stock_moves/stock_move_lines
-- mirror the journal_entries/journal_lines pattern deliberately: draft until
-- posted, posted is immutable, a deferred-style balance rule for transfers.
--
-- Quantities are always stored in the item's BASE unit on the ledger itself
-- (item_units exists so a future UI can let someone type "2 كرتون" and
-- convert via item_unit_to_base(), but the write path here takes base-unit
-- quantities — see docs/data-model.md for what's deferred: price tiers,
-- batch/expiry *enforcement*, and the sales/purchase document flows
-- themselves, which are modules 10/11 and will call into this engine).
-- ============================================================================

create table item_categories (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  sort_order  int not null default 0,
  legacy_no   int,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on item_categories (org_id);

create table warehouses (
  id          uuid primary key default extensions.gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  code        text not null,
  name_ar     text not null,
  name_en     text,
  parent_id   uuid references warehouses(id) on delete restrict,
  is_active   boolean not null default true,
  legacy_no   bigint,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);
create index on warehouses (org_id);

create table items (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  code          text not null,
  barcode       text,
  name_ar       text not null,
  name_en       text,
  category_id   uuid references item_categories(id) on delete restrict,

  base_unit_name text not null default 'قطعة',
  is_stock_tracked boolean not null default true,   -- false = service item, no stock ledger
  track_batches boolean not null default false,
  track_expiry  boolean not null default false,

  sales_price   numeric(19,4) not null default 0 check (sales_price >= 0),
  min_stock     numeric(19,4) check (min_stock >= 0),
  max_stock     numeric(19,4) check (max_stock >= 0),

  -- required (for tracked items) links into the chart of accounts
  inventory_account_id uuid references accounts(id) on delete restrict,
  cogs_account_id       uuid references accounts(id) on delete restrict,
  sales_account_id       uuid references accounts(id) on delete restrict,
  purchase_account_id    uuid references accounts(id) on delete restrict,

  is_active     boolean not null default true,
  legacy_code   text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (org_id, code),
  -- a plain UNIQUE constraint already treats NULL as distinct from NULL, so
  -- any number of items can have no barcode; only actual duplicates collide.
  unique (org_id, barcode),
  constraint items_tracked_needs_accounts check (
    not is_stock_tracked or (inventory_account_id is not null and cogs_account_id is not null)
  ),
  constraint items_stock_range check (max_stock is null or min_stock is null or max_stock >= min_stock)
);
create index on items (org_id);
create index on items (org_id, category_id);
create index items_name_trgm on items using gin (name_ar extensions.gin_trgm_ops);

create table item_units (
  id                uuid primary key default extensions.gen_random_uuid(),
  item_id           uuid not null references items(id) on delete cascade,
  unit_name         text not null,
  conversion_factor numeric(19,6) not null check (conversion_factor > 0),  -- 1 of this unit = N base units
  barcode           text,
  is_purchase_default boolean not null default false,
  is_sales_default     boolean not null default false,
  unique (item_id, unit_name)
);
create index on item_units (item_id);

create or replace function item_unit_to_base(p_item_id uuid, p_unit_id uuid, p_qty numeric)
returns numeric language sql stable as $$
  select p_qty * coalesce((select conversion_factor from item_units where id = p_unit_id and item_id = p_item_id), 1);
$$;

-- ---------------------------------------------------------------------------
-- stock_moves / stock_move_lines
-- ---------------------------------------------------------------------------
create table stock_moves (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  move_no       bigint not null,
  move_date     date not null,
  move_type     text not null check (move_type in
                  ('opening','adjustment_in','adjustment_out','transfer','purchase_in','sale_out')),
  description   text not null default '',

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  source_type   text not null default 'manual',
  source_id     uuid,
  void_of       uuid references stock_moves(id) on delete restrict,
  reversed_by   uuid references stock_moves(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  -- numbered per move_type (its app.next_seq key is 'stock_move_'||move_type),
  -- same convention as vouchers' (org_id, voucher_type, voucher_no)
  unique (org_id, move_type, move_no),
  unique (org_id, source_type, source_id)
);
create index on stock_moves (org_id, move_date);
create index on stock_moves (org_id, status);

create table stock_move_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  move_id       uuid not null references stock_moves(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  direction     text not null check (direction in ('in','out')),

  unit_id       uuid references item_units(id) on delete restrict,   -- null = base unit
  entered_qty   numeric(19,4) not null check (entered_qty > 0),      -- in the chosen unit, for display
  base_qty      numeric(19,4) not null check (base_qty > 0),         -- always in the item's base unit
  unit_cost     numeric(19,4),                                       -- per base unit; required for 'in', computed for 'out' at posting
  total_cost    numeric(19,4) generated always as (base_qty * coalesce(unit_cost, 0)) stored,

  batch_no      text,
  expiry_date   date,
  notes         text,
  created_at    timestamptz not null default now(),

  unique (move_id, line_no)
);
create index on stock_move_lines (move_id);
create index on stock_move_lines (org_id, item_id, warehouse_id);

-- ---------------------------------------------------------------------------
-- Roll-up: current qty + moving-average cost per item/warehouse — O(1) reads
-- ---------------------------------------------------------------------------
create table item_warehouse_balances (
  org_id        uuid not null references organizations(id) on delete cascade,
  item_id       uuid not null references items(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  qty           numeric(19,4) not null default 0,
  avg_cost      numeric(19,4) not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (item_id, warehouse_id)
);
create index on item_warehouse_balances (org_id, warehouse_id);

create or replace function item_stock_on_hand(p_item_id uuid, p_warehouse_id uuid default null)
returns numeric language sql stable as $$
  select coalesce(sum(qty), 0) from item_warehouse_balances
  where item_id = p_item_id and (p_warehouse_id is null or warehouse_id = p_warehouse_id);
$$;

-- ---------------------------------------------------------------------------
-- Validation — draft-only editing, same org, active + tracked item, unit belongs to item
-- ---------------------------------------------------------------------------
create or replace function app.tg_stock_move_line_validate()
returns trigger language plpgsql as $$
declare
  m stock_moves%rowtype;
  it items%rowtype;
  w warehouses%rowtype;
begin
  select * into m from stock_moves where id = new.move_id;
  if not found then raise exception 'stock move line references a missing move' using errcode = '23503'; end if;
  if m.status <> 'draft' then
    raise exception 'move % is %; its lines are frozen', m.move_no, m.status using errcode = '23514';
  end if;
  new.org_id := m.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> m.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_stock_tracked then raise exception 'item % is not stock-tracked', it.code using errcode = '23514'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;

  select * into w from warehouses where id = new.warehouse_id;
  if w.org_id <> m.org_id then raise exception 'warehouse belongs to a different organization' using errcode = '23503'; end if;
  if not w.is_active then raise exception 'warehouse % is inactive', w.code using errcode = '23514'; end if;

  if new.unit_id is not null and (select item_id from item_units where id = new.unit_id) <> new.item_id then
    raise exception 'unit does not belong to this item' using errcode = '23514';
  end if;

  new.base_qty := item_unit_to_base(new.item_id, new.unit_id, new.entered_qty);

  if new.direction = 'in' and (new.unit_cost is null or new.unit_cost < 0) then
    raise exception 'an incoming line needs a unit cost >= 0' using errcode = '23514';
  end if;
  -- Only blank an incoming client-supplied cost on an *out* line at INSERT
  -- time. post_stock_move() itself updates a line's unit_cost while posting
  -- (an out line's real moving-average cost; a transfer-in line's cost
  -- inherited from its source) — those UPDATEs must not be undone by this
  -- same trigger firing on them.
  if new.direction = 'out' and TG_OP = 'INSERT' then
    new.unit_cost := null;
  end if;

  return new;
end;
$$;
create trigger stock_move_line_validate
  before insert or update on stock_move_lines
  for each row execute function app.tg_stock_move_line_validate();

create or replace function app.tg_stock_move_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from stock_moves where id = old.move_id;
  if v_status <> 'draft' then
    raise exception 'move is %; lines cannot be removed', v_status using errcode = '23514';
  end if;
  return old;
end;
$$;
create trigger stock_move_line_frozen_del
  before delete on stock_move_lines
  for each row execute function app.tg_stock_move_line_frozen();

create or replace function app.tg_stock_move_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then
    raise exception 'a void move cannot be modified' using errcode = '23514';
  end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.move_no <> old.move_no or new.move_date <> old.move_date
       or new.move_type <> old.move_type then
      raise exception 'a posted move is immutable; reverse it with void_stock_move()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger stock_move_guard before update on stock_moves for each row execute function app.tg_stock_move_guard();

create trigger set_updated_at before update on items       for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on stock_moves for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on items       for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on stock_moves for each row execute function app.tg_audit();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_stock_move(
  p_org uuid, p_move_type text, p_move_date date, p_description text,
  p_lines jsonb,   -- [{item_id, warehouse_id, direction, entered_qty, unit_id, unit_cost, batch_no, expiry_date, notes}]
  p_source_type text default 'manual', p_source_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_move uuid; v_line jsonb; v_no int := 0;
begin
  perform app.require_permission(p_org, 'inventory.write');

  insert into stock_moves (org_id, move_no, move_date, move_type, description, source_type, source_id, created_by)
  values (p_org, app.next_seq(p_org, 'stock_move_' || p_move_type), p_move_date, p_move_type,
          coalesce(p_description,''), coalesce(p_source_type,'manual'), p_source_id, auth.uid())
  returning id into v_move;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into stock_move_lines (move_id, line_no, item_id, warehouse_id, direction, unit_id,
                                   entered_qty, base_qty, unit_cost, batch_no, expiry_date, notes)
    values (
      v_move, v_no, (v_line->>'item_id')::uuid, (v_line->>'warehouse_id')::uuid,
      coalesce(v_line->>'direction', case when p_move_type in ('adjustment_out','sale_out') then 'out' else 'in' end),
      (v_line->>'unit_id')::uuid,
      (v_line->>'entered_qty')::numeric, (v_line->>'entered_qty')::numeric,  -- base_qty recomputed by the trigger
      nullif(v_line->>'unit_cost','')::numeric,
      v_line->>'batch_no', nullif(v_line->>'expiry_date','')::date, v_line->>'notes'
    );
  end loop;

  return v_move;
end;
$$;

create or replace function post_stock_move(p_move_id uuid, p_contra_account_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  m stock_moves%rowtype;
  l record;
  v_old item_warehouse_balances%rowtype;
  v_new_qty numeric(19,4);
  v_new_avg numeric(19,4);
  v_entry uuid;
  v_period uuid;
  v_line_no int;
begin
  select * into m from stock_moves where id = p_move_id for update;
  if not found then raise exception 'move not found' using errcode = 'P0002'; end if;
  perform app.require_permission(m.org_id, 'inventory.post');
  if m.status <> 'draft' then
    raise exception 'only a draft move can be posted (this one is %)', m.status using errcode = '23514';
  end if;
  if not exists (select 1 from stock_move_lines where move_id = p_move_id) then
    raise exception 'move has no lines' using errcode = '23514';
  end if;

  -- a transfer must balance per item: total in == total out
  if m.move_type = 'transfer' then
    if exists (
      select item_id from stock_move_lines where move_id = p_move_id
      group by item_id
      having coalesce(sum(base_qty) filter (where direction = 'in'), 0)
          <> coalesce(sum(base_qty) filter (where direction = 'out'), 0)
    ) then
      raise exception 'transfer % is unbalanced: each item''s incoming and outgoing quantity must match', m.move_no
        using errcode = '23514';
    end if;
  end if;

  -- A transfer's "in" leg must inherit its cost from what actually left the
  -- source warehouse(s) — never a caller-supplied number (that would let a
  -- transfer manufacture or destroy inventory value). So for transfers we
  -- process every 'out' line first (computing and storing its real cost from
  -- the source warehouse's moving average, same as any other outgoing line),
  -- then process 'in' lines using the quantity-weighted cost of this move's
  -- 'out' lines for that item. Non-transfer moves have no such dependency
  -- between lines, so they're processed in one pass, in line order.
  for l in
    select * from stock_move_lines where move_id = p_move_id
    order by (m.move_type = 'transfer' and direction = 'in'), line_no
    for update
  loop
    select * into v_old from item_warehouse_balances
      where item_id = l.item_id and warehouse_id = l.warehouse_id for update;
    if not found then
      v_old := row(m.org_id, l.item_id, l.warehouse_id, 0, 0, now())::item_warehouse_balances;
    end if;

    if l.direction = 'in' then
      if m.move_type = 'transfer' then
        select round(sum(base_qty * unit_cost) / nullif(sum(base_qty), 0), 4) into l.unit_cost
        from stock_move_lines where move_id = p_move_id and item_id = l.item_id and direction = 'out';
        update stock_move_lines set unit_cost = l.unit_cost where id = l.id;
      end if;
      v_new_qty := v_old.qty + l.base_qty;
      v_new_avg := case when v_new_qty = 0 then 0
                        else round(((v_old.qty * v_old.avg_cost) + (l.base_qty * l.unit_cost)) / v_new_qty, 4) end;
      insert into item_warehouse_balances (org_id, item_id, warehouse_id, qty, avg_cost)
      values (m.org_id, l.item_id, l.warehouse_id, v_new_qty, v_new_avg)
      on conflict (item_id, warehouse_id) do update set qty = v_new_qty, avg_cost = v_new_avg, updated_at = now();
    else
      if v_old.qty < l.base_qty then
        raise exception 'insufficient stock: item % at warehouse has % on hand, need %',
          (select code from items where id = l.item_id), v_old.qty, l.base_qty using errcode = '23514';
      end if;
      v_new_qty := v_old.qty - l.base_qty;
      update stock_move_lines set unit_cost = v_old.avg_cost where id = l.id;
      insert into item_warehouse_balances (org_id, item_id, warehouse_id, qty, avg_cost)
      values (m.org_id, l.item_id, l.warehouse_id, v_new_qty, v_old.avg_cost)
      on conflict (item_id, warehouse_id) do update set qty = v_new_qty, updated_at = now();
    end if;
  end loop;

  -- optional GL posting: a transfer of the same item shares one inventory
  -- account on both legs and always nets to zero, so it never needs one.
  if m.move_type <> 'transfer' and p_contra_account_id is not null then
    v_period := app.open_period_for(m.org_id, m.move_date);
    insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                  source_type, source_id, created_by)
    values (m.org_id, app.next_seq(m.org_id, 'journal'), m.move_date, v_period,
            coalesce(nullif(m.description,''), 'حركة مخزون رقم ' || m.move_no),
            'stock_move', m.id, auth.uid())
    returning id into v_entry;

    v_line_no := 0;
    -- one line per distinct inventory account touched, netted
    for l in
      select it.inventory_account_id acc,
             sum(sml.total_cost) filter (where sml.direction = 'in')  as in_amt,
             sum(sml.total_cost) filter (where sml.direction = 'out') as out_amt
      from stock_move_lines sml join items it on it.id = sml.item_id
      where sml.move_id = p_move_id
      group by it.inventory_account_id
    loop
      v_line_no := v_line_no + 1;
      insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
      select v_entry, v_line_no, l.acc, m.description,
             greatest(coalesce(l.in_amt,0) - coalesce(l.out_amt,0), 0),
             greatest(coalesce(l.out_amt,0) - coalesce(l.in_amt,0), 0),
             o.base_currency_id, 1
      from organizations o where o.id = m.org_id;
    end loop;

    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, v_line_no, p_contra_account_id, m.description,
           greatest(coalesce(sum(sml.total_cost) filter (where sml.direction='out'),0)
                   - coalesce(sum(sml.total_cost) filter (where sml.direction='in'),0), 0),
           greatest(coalesce(sum(sml.total_cost) filter (where sml.direction='in'),0)
                   - coalesce(sum(sml.total_cost) filter (where sml.direction='out'),0), 0),
           (select base_currency_id from organizations where id = m.org_id), 1
    from stock_move_lines sml where sml.move_id = p_move_id;

    update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
    update stock_moves set journal_entry_id = v_entry where id = p_move_id;
  end if;

  update stock_moves set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = p_move_id;
  return p_move_id;
end;
$$;

revoke all on function create_stock_move(uuid,text,date,text,jsonb,text,uuid) from public, anon;
revoke all on function post_stock_move(uuid,uuid) from public, anon;
grant execute on function create_stock_move(uuid,text,date,text,jsonb,text,uuid) to authenticated;
grant execute on function post_stock_move(uuid,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('inventory.write', 'accounting', 'إدارة الأصناف والمستودعات وحركات المخزون (مسودة)', false),
  ('inventory.post',  'accounting', 'ترحيل حركات المخزون',                              true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('inventory.write','inventory.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('inventory.write','inventory.post') on conflict do nothing;

alter table item_categories        enable row level security;
alter table warehouses             enable row level security;
alter table items                  enable row level security;
alter table item_units             enable row level security;
alter table stock_moves            enable row level security;
alter table stock_move_lines       enable row level security;
alter table item_warehouse_balances enable row level security;

create policy itemcat_select on item_categories for select using (app.is_member(org_id));
create policy itemcat_write  on item_categories for all
  using (app.has_permission(org_id, 'inventory.write')) with check (app.has_permission(org_id, 'inventory.write'));

create policy warehouse_select on warehouses for select using (app.is_member(org_id));
create policy warehouse_write  on warehouses for all
  using (app.has_permission(org_id, 'inventory.write')) with check (app.has_permission(org_id, 'inventory.write'));

create policy item_select on items for select using (app.is_member(org_id));
create policy item_write  on items for all
  using (app.has_permission(org_id, 'inventory.write')) with check (app.has_permission(org_id, 'inventory.write'));

create policy item_unit_select on item_units for select using (
  exists (select 1 from items i where i.id = item_id and app.is_member(i.org_id)));
create policy item_unit_write on item_units for all using (
  exists (select 1 from items i where i.id = item_id and app.has_permission(i.org_id, 'inventory.write'))
) with check (
  exists (select 1 from items i where i.id = item_id and app.has_permission(i.org_id, 'inventory.write')));

create policy stock_move_select on stock_moves for select using (app.is_member(org_id));
create policy stock_move_write  on stock_moves for all
  using (app.has_permission(org_id, 'inventory.write')) with check (app.has_permission(org_id, 'inventory.write'));

create policy stock_move_line_select on stock_move_lines for select using (app.is_member(org_id));
create policy stock_move_line_write  on stock_move_lines for all
  using (app.has_permission(org_id, 'inventory.write')) with check (app.has_permission(org_id, 'inventory.write'));

create policy iwb_select on item_warehouse_balances for select using (app.is_member(org_id));
