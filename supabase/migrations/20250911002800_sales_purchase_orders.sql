-- ============================================================================
-- Rotopa · Modules 10/11 (continued) — sales & purchase orders
--
-- Last of the four additions the user picked after comparing against a
-- parallel project. Not a legacy replica — checked analysis/columns.txt
-- earlier this session while scoping the returns feature and found no
-- order-before-invoice document type in the real acc_trn history either.
--
-- Purpose: record a commitment (customer places an order / we order from a
-- supplier) BEFORE any invoice, inventory movement, or GL entry exists —
-- then let ONE order be invoiced across MULTIPLE later invoices (partial
-- deliveries), each of which is a completely normal, fully independent
-- sales_invoice/purchase_invoice created through the EXACT SAME
-- create_sales_invoice()/create_purchase_invoice() RPCs every other path
-- already uses. No new money-posting logic exists anywhere in this file —
-- orders only decide WHAT is allowed to be invoiced and HOW MUCH of it
-- remains, exactly the same "not a new posting engine" principle modules
-- 15/16/POS already established for their own settlement paths.
--
-- Deliberate scope decision: an order does NOT automatically reserve stock
-- (module 09's stock_reservations, built earlier this session). The two
-- features compose — stock_reservations already carries a generic
-- source_type/source_id pair sized for exactly this — but wiring "confirm
-- an order" to "auto-reserve every line" opens a real design question this
-- migration deliberately does NOT answer: what happens to a reservation
-- sized for the FULL order line once only PART of it gets invoiced? A user
-- who wants a specific order's stock held can reserve it manually
-- (source_type='sales_order', source_id=<order id>) today; automating that
-- link is a real future enhancement, not an oversight here.
--
-- "Fully invoiced" is deliberately NOT a stored status. An order's status
-- only tracks what a PERSON does to it (draft/confirmed/cancelled) — how
-- much of it has been invoiced so far is a DERIVED fact (querying invoices
-- that reference it), computed live wherever it's needed, same principle
-- already proven for "how much of this invoice has been returned so far"
-- in the returns feature. A stored fourth status would just be a cache of
-- that same query, one more thing to keep in sync for no real benefit.
-- ============================================================================

create table sales_orders (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  order_no      bigint not null,
  order_date    date not null,
  dealer_id     uuid not null references dealers(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),
  description   text not null default '',

  status        text not null default 'draft' check (status in ('draft','confirmed','cancelled')),
  cancel_reason text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  confirmed_by  uuid references auth.users(id),
  confirmed_at  timestamptz,
  cancelled_by  uuid references auth.users(id),
  cancelled_at  timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, order_no),
  constraint sales_order_confirmed_has_timestamp check (status <> 'confirmed' or confirmed_at is not null),
  constraint sales_order_cancelled_has_timestamp check (status <> 'cancelled' or cancelled_at is not null)
);
create index on sales_orders (org_id, status);
create index on sales_orders (org_id, dealer_id);

create table sales_order_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  order_id      uuid not null references sales_orders(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),
  discount_pct  numeric(6,3) not null default 0 check (discount_pct between 0 and 100),
  unit_id       uuid references item_units(id) on delete restrict,
  base_qty      numeric(19,4) not null check (base_qty > 0),
  line_total    numeric(19,4) generated always as (round(qty * unit_price * (1 - discount_pct / 100.0), 4)) stored,
  unique (order_id, line_no)
);
create index on sales_order_lines (order_id);
create index on sales_order_lines (org_id, item_id);

alter table sales_invoices add column sales_order_id uuid references sales_orders(id) on delete restrict;
create index on sales_invoices (sales_order_id) where sales_order_id is not null;

-- ---------------------------------------------------------------------------
-- Guards — same shape as every draft-then-locked document this project has
-- ---------------------------------------------------------------------------
create or replace function app.tg_sales_order_line_validate()
returns trigger language plpgsql as $$
declare o sales_orders%rowtype; it items%rowtype;
begin
  select * into o from sales_orders where id = new.order_id;
  if not found then raise exception 'order line references a missing order' using errcode = '23503'; end if;
  if o.status <> 'draft' then raise exception 'order % is %; its lines are frozen', o.order_no, o.status using errcode = '23514'; end if;
  new.org_id := o.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> o.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;

  if new.unit_id is not null and (select item_id from item_units where id = new.unit_id) <> new.item_id then
    raise exception 'unit does not belong to this item' using errcode = '23514';
  end if;
  new.base_qty := item_unit_to_base(new.item_id, new.unit_id, new.qty);

  return new;
end;
$$;
create trigger sales_order_line_validate before insert or update on sales_order_lines
  for each row execute function app.tg_sales_order_line_validate();

create or replace function app.tg_sales_order_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from sales_orders where id = old.order_id;
  if v_status <> 'draft' then raise exception 'order is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger sales_order_line_frozen_del before delete on sales_order_lines
  for each row execute function app.tg_sales_order_line_frozen();

create or replace function app.tg_sales_order_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'cancelled' then raise exception 'a cancelled order cannot be modified' using errcode = '23514'; end if;
  if old.status = 'confirmed' then
    if new.status not in ('confirmed','cancelled')
       or new.org_id <> old.org_id or new.dealer_id <> old.dealer_id or new.warehouse_id <> old.warehouse_id
       or new.order_date <> old.order_date then
      raise exception 'a confirmed order''s terms are locked; cancel it instead of editing' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger sales_order_guard before update on sales_orders for each row execute function app.tg_sales_order_guard();
create trigger set_updated_at before update on sales_orders for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on sales_orders for each row execute function app.tg_audit();
create trigger block_delete_unless_draft before delete on sales_orders for each row execute function app.tg_block_delete_unless_draft();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_sales_order(
  p_org uuid, p_order_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct, unit_id}]
  p_currency_id uuid default null, p_rate numeric default 1, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_order uuid; v_line jsonb; v_no int := 0; v_currency uuid; v_is_customer boolean;
begin
  perform app.require_permission(p_org, 'sales.write');

  select is_customer into v_is_customer from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_customer is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_customer then raise exception 'dealer is not marked as a customer' using errcode = '23514'; end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into sales_orders (org_id, order_no, order_date, dealer_id, warehouse_id, currency_id, rate, description, created_by)
  values (p_org, app.next_seq(p_org, 'sales_order'), p_order_date, p_dealer_id, p_warehouse_id, v_currency,
          coalesce(p_rate, 1), coalesce(p_description,''), auth.uid())
  returning id into v_order;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into sales_order_lines (order_id, line_no, item_id, qty, unit_price, discount_pct, unit_id)
    values (v_order, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0), (v_line->>'unit_id')::uuid);
  end loop;

  return v_order;
end;
$$;

create or replace function confirm_sales_order(p_order_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare o sales_orders%rowtype;
begin
  select * into o from sales_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'sales.write');
  if o.status <> 'draft' then raise exception 'only a draft order can be confirmed (this one is %)', o.status using errcode = '23514'; end if;
  if not exists (select 1 from sales_order_lines where order_id = p_order_id) then
    raise exception 'order has no lines' using errcode = '23514';
  end if;

  update sales_orders set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now() where id = p_order_id;
  return p_order_id;
end;
$$;

create or replace function cancel_sales_order(p_order_id uuid, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare o sales_orders%rowtype;
begin
  select * into o from sales_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'sales.write');
  if o.status not in ('draft','confirmed') then
    raise exception 'only a draft or confirmed order can be cancelled (this one is %)', o.status using errcode = '23514';
  end if;

  update sales_orders set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = p_reason
    where id = p_order_id;
  return p_order_id;
end;
$$;

-- Creates a normal DRAFT sales_invoice for some or all of a confirmed
-- order's remaining quantity — the invoice is then edited/posted/voided
-- exactly like any invoice created from scratch, through the exact same
-- create_sales_invoice() this calls. Price/unit are always the order's own
-- (never re-typed), same "commercial terms were locked when confirmed"
-- principle as everywhere else quantities/prices get inherited in this schema.
create or replace function invoice_sales_order(
  p_order_id uuid,
  p_lines jsonb,   -- [{item_id, qty}]
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_due_date date default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o sales_orders%rowtype;
  v_invoice uuid; v_line jsonb; v_item uuid; v_qty numeric; v_orig record; v_already numeric;
  v_invoice_lines jsonb := '[]'::jsonb;
begin
  select * into o from sales_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  if o.status <> 'confirmed' then raise exception 'only a confirmed order can be invoiced (this one is %)', o.status using errcode = '23514'; end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_item := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select qty, unit_price, discount_pct, unit_id into v_orig
    from sales_order_lines where order_id = p_order_id and item_id = v_item;
    if not found then raise exception 'item is not on this order' using errcode = '23514'; end if;

    select coalesce(sum(sil.qty), 0) into v_already
    from sales_invoice_lines sil join sales_invoices si on si.id = sil.invoice_id
    where si.sales_order_id = p_order_id and sil.item_id = v_item and si.status <> 'void';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot invoice % — only % of % remains on this order for this item', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    v_invoice_lines := v_invoice_lines || jsonb_build_object(
      'item_id', v_item, 'qty', v_qty, 'unit_price', v_orig.unit_price,
      'discount_pct', v_orig.discount_pct, 'unit_id', v_orig.unit_id);
  end loop;

  if jsonb_array_length(v_invoice_lines) = 0 then raise exception 'no lines to invoice' using errcode = '23514'; end if;

  v_invoice := create_sales_invoice(o.org_id, current_date, o.dealer_id, o.warehouse_id, v_invoice_lines,
    o.currency_id, o.rate, coalesce(p_payment_method,'credit'), p_cash_account_id,
    coalesce(nullif(p_description,''), 'فاتورة على طلب رقم ' || o.order_no), p_due_date);

  update sales_invoices set sales_order_id = p_order_id where id = v_invoice;

  return v_invoice;
end;
$$;

revoke all on function create_sales_order(uuid,date,uuid,uuid,jsonb,uuid,numeric,text) from public, anon;
revoke all on function confirm_sales_order(uuid) from public, anon;
revoke all on function cancel_sales_order(uuid,text) from public, anon;
revoke all on function invoice_sales_order(uuid,jsonb,text,uuid,date,text) from public, anon;
grant execute on function create_sales_order(uuid,date,uuid,uuid,jsonb,uuid,numeric,text) to authenticated;
grant execute on function confirm_sales_order(uuid) to authenticated;
grant execute on function cancel_sales_order(uuid,text) to authenticated;
grant execute on function invoice_sales_order(uuid,jsonb,text,uuid,date,text) to authenticated;

alter table sales_orders      enable row level security;
alter table sales_order_lines enable row level security;

create policy sales_order_select on sales_orders for select using (app.is_member(org_id));
create policy sales_order_write  on sales_orders for all
  using (app.has_permission(org_id, 'sales.write')) with check (app.has_permission(org_id, 'sales.write'));
create policy sales_order_line_select on sales_order_lines for select using (app.is_member(org_id));
create policy sales_order_line_write  on sales_order_lines for all
  using (app.has_permission(org_id, 'sales.write')) with check (app.has_permission(org_id, 'sales.write'));

-- ============================================================================
-- Purchase orders — exact mirror of the above
-- ============================================================================

create table purchase_orders (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  order_no      bigint not null,
  order_date    date not null,
  dealer_id     uuid not null references dealers(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),
  description   text not null default '',

  status        text not null default 'draft' check (status in ('draft','confirmed','cancelled')),
  cancel_reason text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  confirmed_by  uuid references auth.users(id),
  confirmed_at  timestamptz,
  cancelled_by  uuid references auth.users(id),
  cancelled_at  timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, order_no),
  constraint purchase_order_confirmed_has_timestamp check (status <> 'confirmed' or confirmed_at is not null),
  constraint purchase_order_cancelled_has_timestamp check (status <> 'cancelled' or cancelled_at is not null)
);
create index on purchase_orders (org_id, status);
create index on purchase_orders (org_id, dealer_id);

create table purchase_order_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  order_id      uuid not null references purchase_orders(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),
  discount_pct  numeric(6,3) not null default 0 check (discount_pct between 0 and 100),
  unit_id       uuid references item_units(id) on delete restrict,
  base_qty      numeric(19,4) not null check (base_qty > 0),
  line_total    numeric(19,4) generated always as (round(qty * unit_price * (1 - discount_pct / 100.0), 4)) stored,
  unique (order_id, line_no)
);
create index on purchase_order_lines (order_id);
create index on purchase_order_lines (org_id, item_id);

alter table purchase_invoices add column purchase_order_id uuid references purchase_orders(id) on delete restrict;
create index on purchase_invoices (purchase_order_id) where purchase_order_id is not null;

create or replace function app.tg_purchase_order_line_validate()
returns trigger language plpgsql as $$
declare o purchase_orders%rowtype; it items%rowtype;
begin
  select * into o from purchase_orders where id = new.order_id;
  if not found then raise exception 'order line references a missing order' using errcode = '23503'; end if;
  if o.status <> 'draft' then raise exception 'order % is %; its lines are frozen', o.order_no, o.status using errcode = '23514'; end if;
  new.org_id := o.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> o.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;

  if new.unit_id is not null and (select item_id from item_units where id = new.unit_id) <> new.item_id then
    raise exception 'unit does not belong to this item' using errcode = '23514';
  end if;
  new.base_qty := item_unit_to_base(new.item_id, new.unit_id, new.qty);

  return new;
end;
$$;
create trigger purchase_order_line_validate before insert or update on purchase_order_lines
  for each row execute function app.tg_purchase_order_line_validate();

create or replace function app.tg_purchase_order_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from purchase_orders where id = old.order_id;
  if v_status <> 'draft' then raise exception 'order is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger purchase_order_line_frozen_del before delete on purchase_order_lines
  for each row execute function app.tg_purchase_order_line_frozen();

create or replace function app.tg_purchase_order_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'cancelled' then raise exception 'a cancelled order cannot be modified' using errcode = '23514'; end if;
  if old.status = 'confirmed' then
    if new.status not in ('confirmed','cancelled')
       or new.org_id <> old.org_id or new.dealer_id <> old.dealer_id or new.warehouse_id <> old.warehouse_id
       or new.order_date <> old.order_date then
      raise exception 'a confirmed order''s terms are locked; cancel it instead of editing' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger purchase_order_guard before update on purchase_orders for each row execute function app.tg_purchase_order_guard();
create trigger set_updated_at before update on purchase_orders for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on purchase_orders for each row execute function app.tg_audit();
create trigger block_delete_unless_draft before delete on purchase_orders for each row execute function app.tg_block_delete_unless_draft();

create or replace function create_purchase_order(
  p_org uuid, p_order_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct, unit_id}]
  p_currency_id uuid default null, p_rate numeric default 1, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_order uuid; v_line jsonb; v_no int := 0; v_currency uuid; v_is_supplier boolean;
begin
  perform app.require_permission(p_org, 'purchases.write');

  select is_supplier into v_is_supplier from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_supplier is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_supplier then raise exception 'dealer is not marked as a supplier' using errcode = '23514'; end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into purchase_orders (org_id, order_no, order_date, dealer_id, warehouse_id, currency_id, rate, description, created_by)
  values (p_org, app.next_seq(p_org, 'purchase_order'), p_order_date, p_dealer_id, p_warehouse_id, v_currency,
          coalesce(p_rate, 1), coalesce(p_description,''), auth.uid())
  returning id into v_order;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into purchase_order_lines (order_id, line_no, item_id, qty, unit_price, discount_pct, unit_id)
    values (v_order, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0), (v_line->>'unit_id')::uuid);
  end loop;

  return v_order;
end;
$$;

create or replace function confirm_purchase_order(p_order_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare o purchase_orders%rowtype;
begin
  select * into o from purchase_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'purchases.write');
  if o.status <> 'draft' then raise exception 'only a draft order can be confirmed (this one is %)', o.status using errcode = '23514'; end if;
  if not exists (select 1 from purchase_order_lines where order_id = p_order_id) then
    raise exception 'order has no lines' using errcode = '23514';
  end if;

  update purchase_orders set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now() where id = p_order_id;
  return p_order_id;
end;
$$;

create or replace function cancel_purchase_order(p_order_id uuid, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare o purchase_orders%rowtype;
begin
  select * into o from purchase_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'purchases.write');
  if o.status not in ('draft','confirmed') then
    raise exception 'only a draft or confirmed order can be cancelled (this one is %)', o.status using errcode = '23514';
  end if;

  update purchase_orders set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = p_reason
    where id = p_order_id;
  return p_order_id;
end;
$$;

create or replace function invoice_purchase_order(
  p_order_id uuid,
  p_lines jsonb,   -- [{item_id, qty}]
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_due_date date default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o purchase_orders%rowtype;
  v_invoice uuid; v_line jsonb; v_item uuid; v_qty numeric; v_orig record; v_already numeric;
  v_invoice_lines jsonb := '[]'::jsonb;
begin
  select * into o from purchase_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  if o.status <> 'confirmed' then raise exception 'only a confirmed order can be invoiced (this one is %)', o.status using errcode = '23514'; end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_item := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select qty, unit_price, discount_pct, unit_id into v_orig
    from purchase_order_lines where order_id = p_order_id and item_id = v_item;
    if not found then raise exception 'item is not on this order' using errcode = '23514'; end if;

    select coalesce(sum(pil.qty), 0) into v_already
    from purchase_invoice_lines pil join purchase_invoices pi on pi.id = pil.invoice_id
    where pi.purchase_order_id = p_order_id and pil.item_id = v_item and pi.status <> 'void';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot invoice % — only % of % remains on this order for this item', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    v_invoice_lines := v_invoice_lines || jsonb_build_object(
      'item_id', v_item, 'qty', v_qty, 'unit_price', v_orig.unit_price,
      'discount_pct', v_orig.discount_pct, 'unit_id', v_orig.unit_id);
  end loop;

  if jsonb_array_length(v_invoice_lines) = 0 then raise exception 'no lines to invoice' using errcode = '23514'; end if;

  v_invoice := create_purchase_invoice(o.org_id, current_date, o.dealer_id, o.warehouse_id, v_invoice_lines,
    o.currency_id, o.rate, coalesce(p_payment_method,'credit'), p_cash_account_id,
    coalesce(nullif(p_description,''), 'فاتورة على طلب رقم ' || o.order_no), p_due_date);

  update purchase_invoices set purchase_order_id = p_order_id where id = v_invoice;

  return v_invoice;
end;
$$;

revoke all on function create_purchase_order(uuid,date,uuid,uuid,jsonb,uuid,numeric,text) from public, anon;
revoke all on function confirm_purchase_order(uuid) from public, anon;
revoke all on function cancel_purchase_order(uuid,text) from public, anon;
revoke all on function invoice_purchase_order(uuid,jsonb,text,uuid,date,text) from public, anon;
grant execute on function create_purchase_order(uuid,date,uuid,uuid,jsonb,uuid,numeric,text) to authenticated;
grant execute on function confirm_purchase_order(uuid) to authenticated;
grant execute on function cancel_purchase_order(uuid,text) to authenticated;
grant execute on function invoice_purchase_order(uuid,jsonb,text,uuid,date,text) to authenticated;

alter table purchase_orders      enable row level security;
alter table purchase_order_lines enable row level security;

create policy purchase_order_select on purchase_orders for select using (app.is_member(org_id));
create policy purchase_order_write  on purchase_orders for all
  using (app.has_permission(org_id, 'purchases.write')) with check (app.has_permission(org_id, 'purchases.write'));
create policy purchase_order_line_select on purchase_order_lines for select using (app.is_member(org_id));
create policy purchase_order_line_write  on purchase_order_lines for all
  using (app.has_permission(org_id, 'purchases.write')) with check (app.has_permission(org_id, 'purchases.write'));
