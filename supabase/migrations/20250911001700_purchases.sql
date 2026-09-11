-- ============================================================================
-- Rotopa · Module 11 — Purchase invoicing
--
-- The mirror image of module 10 (sales), but simpler: a purchase is ONE
-- economic event (buy inventory), not two. Sales needed a 4-legged entry
-- because it recognises revenue (Dr AR/cash, Cr revenue) AND cost of goods
-- sold (Dr COGS, Cr inventory) at once, using a cost the engine has to
-- compute. A purchase just needs Dr inventory / Cr AP-or-cash, at the cost
-- the invoice itself states — nothing to compute, the invoice line IS the
-- cost basis for what the stock engine records.
-- ============================================================================

create table purchase_invoices (
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
  void_of       uuid references purchase_invoices(id) on delete restrict,
  reversed_by   uuid references purchase_invoices(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, invoice_no),
  constraint purchase_invoice_cash_needs_account check (payment_method <> 'cash' or cash_account_id is not null),
  constraint purchase_invoice_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on purchase_invoices (org_id, invoice_date);
create index on purchase_invoices (org_id, status);
create index on purchase_invoices (dealer_id);

create table purchase_invoice_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  invoice_id    uuid not null references purchase_invoices(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),   -- the purchase cost per unit — IS the cost basis, nothing to compute later
  discount_pct  numeric(6,3) not null default 0 check (discount_pct between 0 and 100),
  line_total    numeric(19,4) generated always as (round(qty * unit_price * (1 - discount_pct / 100.0), 4)) stored,

  unique (invoice_id, line_no)
);
create index on purchase_invoice_lines (invoice_id);
create index on purchase_invoice_lines (org_id, item_id);

-- ---------------------------------------------------------------------------
-- Validation & guards — same shape as sales_invoice_lines/sales_invoices
-- ---------------------------------------------------------------------------
create or replace function app.tg_purchase_invoice_line_validate()
returns trigger language plpgsql as $$
declare inv purchase_invoices%rowtype; it items%rowtype;
begin
  select * into inv from purchase_invoices where id = new.invoice_id;
  if not found then raise exception 'invoice line references a missing invoice' using errcode = '23503'; end if;
  if inv.status <> 'draft' then
    raise exception 'invoice % is %; its lines are frozen', inv.invoice_no, inv.status using errcode = '23514';
  end if;
  new.org_id := inv.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> inv.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;
  if not it.is_stock_tracked then raise exception 'item % does not track stock and cannot be purchased this way yet', it.code using errcode = '23514'; end if;

  return new;
end;
$$;
create trigger purchase_invoice_line_validate
  before insert or update on purchase_invoice_lines
  for each row execute function app.tg_purchase_invoice_line_validate();

create or replace function app.tg_purchase_invoice_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from purchase_invoices where id = old.invoice_id;
  if v_status <> 'draft' then raise exception 'invoice is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger purchase_invoice_line_frozen_del
  before delete on purchase_invoice_lines
  for each row execute function app.tg_purchase_invoice_line_frozen();

create or replace function app.tg_purchase_invoice_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then raise exception 'a void invoice cannot be modified' using errcode = '23514'; end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.invoice_no <> old.invoice_no or new.invoice_date <> old.invoice_date
       or new.dealer_id <> old.dealer_id or new.warehouse_id <> old.warehouse_id then
      raise exception 'a posted invoice is immutable; reverse it with void_purchase_invoice()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger purchase_invoice_guard before update on purchase_invoices for each row execute function app.tg_purchase_invoice_guard();

create trigger set_updated_at before update on purchase_invoices for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on purchase_invoices for each row execute function app.tg_audit();

-- posted/void rows may not be deleted, only drafts — same rule as every
-- other posted-document table (20250911001500_delete_guards.sql)
create trigger block_delete_unless_draft
  before delete on purchase_invoices
  for each row execute function app.tg_block_delete_unless_draft();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_purchase_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_invoice uuid; v_line jsonb; v_no int := 0;
  v_currency uuid; v_is_supplier boolean;
begin
  perform app.require_permission(p_org, 'purchases.write');

  select is_supplier into v_is_supplier from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_supplier is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_supplier then raise exception 'dealer is not marked as a supplier' using errcode = '23514'; end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into purchase_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                                  payment_method, cash_account_id, description, created_by)
  values (p_org, app.next_seq(p_org, 'purchase_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), auth.uid())
  returning id into v_invoice;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into purchase_invoice_lines (invoice_id, line_no, item_id, qty, unit_price, discount_pct)
    values (v_invoice, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0));
  end loop;

  return v_invoice;
end;
$$;

-- Same nested-permission consequence as post_sales_invoice: posting needs
-- inventory.write + inventory.post alongside purchases.*, because
-- create_stock_move/post_stock_move run as the real caller through
-- SECURITY DEFINER, not as this function's own identity. Owner/accountant
-- already carry every permission, so invisible today — a future narrower
-- "purchasing clerk" role will need both grants.
create or replace function post_purchase_invoice(p_invoice_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_total numeric(19,4) := 0;
  g record;
begin
  select * into inv from purchase_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'purchases.post');
  if inv.status <> 'draft' then
    raise exception 'only a draft invoice can be posted (this one is %)', inv.status using errcode = '23514';
  end if;
  if not exists (select 1 from purchase_invoice_lines where invoice_id = p_invoice_id) then
    raise exception 'invoice has no lines' using errcode = '23514';
  end if;

  -- 1) receive stock at exactly what the invoice says it cost — the line's
  --    net unit price (after its own discount) becomes the weighted-average
  --    engine's input cost, same value the GL entry below uses.
  v_move := create_stock_move(inv.org_id, 'purchase_in', inv.invoice_date,
    'فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'entered_qty', l.qty, 'unit_cost', round(l.line_total / l.qty, 4)))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice', inv.id);
  perform post_stock_move(v_move);

  -- 2) the financial entry
  v_period := app.open_period_for(inv.org_id, inv.invoice_date);
  select sum(line_total) into v_total from purchase_invoice_lines where invoice_id = p_invoice_id;

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مشتريات رقم ' || inv.invoice_no),
          'purchase_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

  -- Dr inventory, grouped by each item's own inventory account, at the same
  -- cost the stock move just recorded
  for g in
    select it.inventory_account_id acc, sum(l.line_total) amt
    from purchase_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'فاتورة مشتريات رقم ' || inv.invoice_no, round(g.amt * inv.rate, 4), 0, inv.currency_id, inv.rate);
  end loop;

  -- Cr AP (dealer) or Cr cash, for the invoice total
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مشتريات رقم ' || inv.invoice_no, 0, round(v_total * inv.rate, 4), inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update purchase_invoices set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                               posted_by = auth.uid(), posted_at = now()
    where id = p_invoice_id;

  return v_entry;
end;
$$;

create or replace function void_purchase_invoice(p_invoice_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_rev uuid;
begin
  select * into inv from purchase_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'purchases.post');
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be voided' using errcode = '23514'; end if;

  -- remove the stock that came in, at whatever it's worth NOW (current
  -- moving average) — not the original purchase cost, since some of it may
  -- have sold since. Same engine-computed-cost rule as any adjustment_out.
  -- Fails naturally (insufficient stock) if less remains than was received,
  -- which is the correct business outcome, not a bug to work around.
  v_move := create_stock_move(inv.org_id, 'adjustment_out', p_date, 'مرجع فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'out', 'entered_qty', l.qty))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice_void', inv.id);
  perform post_stock_move(v_move);

  -- mirror the original financial entry
  v_period := app.open_period_for(inv.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), p_date, v_period,
          'إلغاء فاتورة مشتريات رقم ' || inv.invoice_no || coalesce(' — ' || p_reason, ''),
          'reversal', inv.journal_entry_id, inv.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = inv.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = inv.journal_entry_id;

  insert into purchase_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                                  payment_method, cash_account_id, description, journal_entry_id, stock_move_id,
                                  void_of, status, created_by, posted_by, posted_at)
  values (inv.org_id, app.next_seq(inv.org_id, 'purchase_invoice'), p_date, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, inv.payment_method, inv.cash_account_id,
          'إلغاء فاتورة رقم ' || inv.invoice_no, v_entry, v_move, inv.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update purchase_invoices set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = inv.id;

  return v_rev;
end;
$$;

revoke all on function create_purchase_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text) from public, anon;
revoke all on function post_purchase_invoice(uuid) from public, anon;
revoke all on function void_purchase_invoice(uuid,date,text) from public, anon;
grant execute on function create_purchase_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text) to authenticated;
grant execute on function post_purchase_invoice(uuid) to authenticated;
grant execute on function void_purchase_invoice(uuid,date,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('purchases.write', 'accounting', 'إنشاء وتعديل فواتير مشتريات مسودة', false),
  ('purchases.post',  'accounting', 'ترحيل وإلغاء فواتير المشتريات',     true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('purchases.write','purchases.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('purchases.write','purchases.post') on conflict do nothing;

alter table purchase_invoices      enable row level security;
alter table purchase_invoice_lines enable row level security;

create policy purchase_invoice_select on purchase_invoices for select using (app.is_member(org_id));
create policy purchase_invoice_write  on purchase_invoices for all
  using (app.has_permission(org_id, 'purchases.write')) with check (app.has_permission(org_id, 'purchases.write'));

create policy purchase_invoice_line_select on purchase_invoice_lines for select using (app.is_member(org_id));
create policy purchase_invoice_line_write  on purchase_invoice_lines for all
  using (app.has_permission(org_id, 'purchases.write')) with check (app.has_permission(org_id, 'purchases.write'));
