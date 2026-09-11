-- ============================================================================
-- Rotopa · Module 10 — Sales invoicing
--
-- An invoice orchestrates two things that must both succeed or neither does:
--   1. the inventory engine (module 09) — deducts stock at its real
--      moving-average cost (post_stock_move, GL posting left off: the
--      invoice builds its own complete entry instead of the move's simpler
--      one-contra-account version)
--   2. a four-legged journal entry: Dr AR/cash, Cr revenue, Dr COGS, Cr
--      inventory — using the ACTUAL cost the stock engine just computed,
--      never a price the client supplies.
-- ============================================================================

create table sales_invoices (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  invoice_no    bigint not null,
  invoice_date  date not null,
  dealer_id     uuid not null references dealers(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),
  payment_method text not null default 'credit' check (payment_method in ('credit','cash')),
  cash_account_id uuid references accounts(id) on delete restrict,   -- required when payment_method='cash'
  description   text not null default '',

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  stock_move_id     uuid references stock_moves(id) on delete restrict,
  void_of       uuid references sales_invoices(id) on delete restrict,
  reversed_by   uuid references sales_invoices(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, invoice_no),
  constraint sales_invoice_cash_needs_account check (payment_method <> 'cash' or cash_account_id is not null),
  constraint sales_invoice_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on sales_invoices (org_id, invoice_date);
create index on sales_invoices (org_id, status);
create index on sales_invoices (dealer_id);

create table sales_invoice_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  invoice_id    uuid not null references sales_invoices(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),
  discount_pct  numeric(6,3) not null default 0 check (discount_pct between 0 and 100),
  line_total    numeric(19,4) generated always as (round(qty * unit_price * (1 - discount_pct / 100.0), 4)) stored,
  -- filled in by post_sales_invoice() from the stock engine's real cost — never client-supplied
  unit_cost     numeric(19,4),

  unique (invoice_id, line_no)
);
create index on sales_invoice_lines (invoice_id);
create index on sales_invoice_lines (org_id, item_id);

-- ---------------------------------------------------------------------------
-- Validation & guards
-- ---------------------------------------------------------------------------
create or replace function app.tg_sales_invoice_line_validate()
returns trigger language plpgsql as $$
declare inv sales_invoices%rowtype; it items%rowtype;
begin
  select * into inv from sales_invoices where id = new.invoice_id;
  if not found then raise exception 'invoice line references a missing invoice' using errcode = '23503'; end if;
  if inv.status <> 'draft' then
    raise exception 'invoice % is %; its lines are frozen', inv.invoice_no, inv.status using errcode = '23514';
  end if;
  new.org_id := inv.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> inv.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;
  if not it.is_stock_tracked then raise exception 'item % does not track stock and cannot be sold this way yet', it.code using errcode = '23514'; end if;

  return new;
end;
$$;
create trigger sales_invoice_line_validate
  before insert or update on sales_invoice_lines
  for each row execute function app.tg_sales_invoice_line_validate();

create or replace function app.tg_sales_invoice_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from sales_invoices where id = old.invoice_id;
  if v_status <> 'draft' then raise exception 'invoice is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger sales_invoice_line_frozen_del
  before delete on sales_invoice_lines
  for each row execute function app.tg_sales_invoice_line_frozen();

create or replace function app.tg_sales_invoice_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then raise exception 'a void invoice cannot be modified' using errcode = '23514'; end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.invoice_no <> old.invoice_no or new.invoice_date <> old.invoice_date
       or new.dealer_id <> old.dealer_id or new.warehouse_id <> old.warehouse_id then
      raise exception 'a posted invoice is immutable; reverse it with void_sales_invoice()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger sales_invoice_guard before update on sales_invoices for each row execute function app.tg_sales_invoice_guard();

create trigger set_updated_at before update on sales_invoices for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on sales_invoices for each row execute function app.tg_audit();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_sales_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_invoice uuid; v_line jsonb; v_no int := 0;
  v_currency uuid; v_is_customer boolean;
begin
  perform app.require_permission(p_org, 'sales.write');

  select is_customer into v_is_customer from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_customer is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_customer then raise exception 'dealer is not marked as a customer' using errcode = '23514'; end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into sales_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                               payment_method, cash_account_id, description, created_by)
  values (p_org, app.next_seq(p_org, 'sales_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), auth.uid())
  returning id into v_invoice;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into sales_invoice_lines (invoice_id, line_no, item_id, qty, unit_price, discount_pct)
    values (v_invoice, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0));
  end loop;

  return v_invoice;
end;
$$;

-- Calls create_stock_move()/post_stock_move() rather than re-deriving
-- moving-average costing inline (one implementation of that math, not two
-- that could drift apart). Consequence, stated plainly: posting a sales
-- invoice needs inventory.write + inventory.post in addition to sales.*,
-- because auth.uid() still resolves to the real caller through the nested
-- SECURITY DEFINER call. The seeded owner/accountant roles already carry
-- every permission, so this is invisible in practice — but a future
-- narrower "sales clerk" role will need both grants, not just sales.*.
create or replace function post_sales_invoice(
  p_invoice_id uuid,
  p_default_sales_account_id uuid default null   -- used only for an item missing its own sales_account_id
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_total numeric(19,4) := 0;
  g record;
begin
  select * into inv from sales_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'sales.post');
  if inv.status <> 'draft' then
    raise exception 'only a draft invoice can be posted (this one is %)', inv.status using errcode = '23514';
  end if;
  if not exists (select 1 from sales_invoice_lines where invoice_id = p_invoice_id) then
    raise exception 'invoice has no lines' using errcode = '23514';
  end if;

  -- 1) deduct stock at whatever it actually costs — the invoice's own
  --    unit_price never influences this. p_contra_account_id is left null:
  --    the invoice posts the complete inventory/COGS entry itself below.
  v_move := create_stock_move(inv.org_id, 'sale_out', inv.invoice_date,
    'فاتورة مبيعات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'out', 'entered_qty', l.qty))
     from sales_invoice_lines l where l.invoice_id = p_invoice_id),
    'sales_invoice', inv.id);
  perform post_stock_move(v_move);

  -- pull the real costs back onto the invoice lines
  update sales_invoice_lines sil
    set unit_cost = sml.unit_cost
  from stock_move_lines sml
  where sml.move_id = v_move and sml.item_id = sil.item_id and sil.invoice_id = p_invoice_id;

  -- 2) the financial entry
  v_period := app.open_period_for(inv.org_id, inv.invoice_date);
  select sum(line_total) into v_total from sales_invoice_lines where invoice_id = p_invoice_id;

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مبيعات رقم ' || inv.invoice_no),
          'sales_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

  -- Dr AR (dealer) or Dr cash, for the invoice total
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مبيعات رقم ' || inv.invoice_no, round(v_total * inv.rate, 4), 0, inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

  -- Cr revenue, grouped by each item's sales account (falling back to the default)
  for g in
    select coalesce(it.sales_account_id, p_default_sales_account_id) acc, sum(l.line_total) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by coalesce(it.sales_account_id, p_default_sales_account_id)
  loop
    if g.acc is null then
      raise exception 'an item on this invoice has no sales account and no default was given' using errcode = '23514';
    end if;
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مبيعات', 0, round(g.amt * inv.rate, 4), inv.currency_id, inv.rate);
  end loop;

  -- Dr COGS / Cr inventory, grouped by each item's own accounts, at the real cost just computed
  for g in
    select it.cogs_account_id acc, sum(l.qty * l.unit_cost) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'تكلفة البضاعة المباعة', round(g.amt, 4), 0, inv.currency_id, 1);
  end loop;
  for g in
    select it.inventory_account_id acc, sum(l.qty * l.unit_cost) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'تكلفة البضاعة المباعة', 0, round(g.amt, 4), inv.currency_id, 1);
  end loop;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update sales_invoices set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                            posted_by = auth.uid(), posted_at = now()
    where id = p_invoice_id;

  return v_entry;
end;
$$;

create or replace function void_sales_invoice(p_invoice_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_rev uuid;
  v_line_no int;
begin
  select * into inv from sales_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'sales.post');
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be voided' using errcode = '23514'; end if;

  -- restock at the same cost that left, via a fresh stock move (immutable history)
  v_move := create_stock_move(inv.org_id, 'adjustment_in', p_date, 'مرجع فاتورة مبيعات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from sales_invoice_lines l where l.invoice_id = p_invoice_id),
    'sales_invoice_void', inv.id);
  perform post_stock_move(v_move);

  -- mirror the original financial entry
  v_period := app.open_period_for(inv.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), p_date, v_period,
          'إلغاء فاتورة مبيعات رقم ' || inv.invoice_no || coalesce(' — ' || p_reason, ''),
          'reversal', inv.journal_entry_id, inv.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = inv.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = inv.journal_entry_id;

  insert into sales_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                               payment_method, cash_account_id, description, journal_entry_id, stock_move_id,
                               void_of, status, created_by, posted_by, posted_at)
  values (inv.org_id, app.next_seq(inv.org_id, 'sales_invoice'), p_date, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, inv.payment_method, inv.cash_account_id,
          'إلغاء فاتورة رقم ' || inv.invoice_no, v_entry, v_move, inv.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update sales_invoices set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = inv.id;

  return v_rev;
end;
$$;

revoke all on function create_sales_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text) from public, anon;
revoke all on function post_sales_invoice(uuid,uuid) from public, anon;
revoke all on function void_sales_invoice(uuid,date,text) from public, anon;
grant execute on function create_sales_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text) to authenticated;
grant execute on function post_sales_invoice(uuid,uuid) to authenticated;
grant execute on function void_sales_invoice(uuid,date,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('sales.write', 'accounting', 'إنشاء وتعديل فواتير مبيعات مسودة', false),
  ('sales.post',  'accounting', 'ترحيل وإلغاء فواتير المبيعات',     true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('sales.write','sales.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('sales.write','sales.post') on conflict do nothing;

alter table sales_invoices      enable row level security;
alter table sales_invoice_lines enable row level security;

create policy sales_invoice_select on sales_invoices for select using (app.is_member(org_id));
create policy sales_invoice_write  on sales_invoices for all
  using (app.has_permission(org_id, 'sales.write')) with check (app.has_permission(org_id, 'sales.write'));

create policy sales_invoice_line_select on sales_invoice_lines for select using (app.is_member(org_id));
create policy sales_invoice_line_write  on sales_invoice_lines for all
  using (app.has_permission(org_id, 'sales.write')) with check (app.has_permission(org_id, 'sales.write'));
