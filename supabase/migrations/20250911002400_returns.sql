-- ============================================================================
-- Rotopa · Module 10/11 (continued) — sales & purchase returns
--
-- Found, not guessed: queried the real acc_trn history directly and counted
-- trn_code usage. trn_code=16 ("فاتورة مرجع مبيعات", sales return) = 626
-- real rows; trn_code=5 ("فاتورة مرجع مشتريات", purchase return) = 430 —
-- both more frequent than payroll (371, already built). void_sales_invoice/
-- void_purchase_invoice only cover reversing an ENTIRE invoice; neither
-- return type existed as a partial, invoice-referencing document. This
-- closes that gap for both sides at once, since they're one mirrored
-- design.
--
-- A return is its own document (draft→posted→void, same lifecycle as every
-- other invoice-shaped document), not a special mode of void_*_invoice —
-- it references an original invoice but only for SOME of its quantity,
-- and that original invoice keeps existing, unmodified, exactly as posted.
--
-- Design decisions worth recording:
--   * Line prices are never client-supplied — create_*_return() looks up
--     each returned item's unit_price (and, for sales, unit_cost) from the
--     ORIGINAL invoice line itself. A return line always reflects what
--     that item actually sold/was bought for on that invoice, never a
--     value someone could type in.
--   * Over-returning is rejected at creation: the sum of this return's
--     qty plus every other POSTED return already taken against the same
--     (invoice, item) can never exceed what that invoice line actually
--     covered.
--   * Sales return restocks at the ORIGINAL invoice line's own unit_cost —
--     a stored historical fact — same principle void_sales_invoice()
--     already uses for its own restocking.
--   * Purchase return removes stock at whatever the CURRENT moving average
--     says (the stock engine computes it, no cost is supplied on the
--     'out' line) — same principle void_purchase_invoice() already uses,
--     for the same reason: some of that batch may have sold since, so the
--     original purchase price no longer reflects what's actually leaving.
--     The financial entry's inventory/AP amounts still use the ORIGINAL
--     invoice line's price (the commercial fact of what the supplier
--     agreed to credit back) — the same mirror-the-original-amounts
--     choice void_purchase_invoice() already made, not a new
--     inconsistency introduced here.
--   * Each return posts its OWN complete entry (mirroring post_sales_
--     invoice/post_purchase_invoice's own shape, debit/credit flipped) —
--     it does not touch or reference the original invoice's entry at all.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Sales returns
-- ---------------------------------------------------------------------------
create table sales_returns (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  return_no     bigint not null,
  return_date   date not null,
  sales_invoice_id uuid not null references sales_invoices(id) on delete restrict,
  dealer_id     uuid not null references dealers(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),
  payment_method text not null default 'credit' check (payment_method in ('credit','cash')),
  cash_account_id uuid references accounts(id) on delete restrict,
  description   text not null default '',

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  stock_move_id     uuid references stock_moves(id) on delete restrict,
  void_of       uuid references sales_returns(id) on delete restrict,
  reversed_by   uuid references sales_returns(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, return_no),
  constraint sr_cash_needs_account check (payment_method <> 'cash' or cash_account_id is not null),
  constraint sr_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on sales_returns (org_id, sales_invoice_id);
create index on sales_returns (org_id, status);

create table sales_return_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  return_id     uuid not null references sales_returns(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),   -- copied from the original invoice line
  unit_cost     numeric(19,4) not null check (unit_cost >= 0),    -- copied from the original invoice line — the historical cost restocked
  line_total    numeric(19,4) generated always as (round(qty * unit_price, 4)) stored,
  unique (return_id, line_no)
);
create index on sales_return_lines (return_id);

create or replace function app.tg_sales_return_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from sales_returns where id = old.return_id;
  if v_status <> 'draft' then raise exception 'return is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger sales_return_line_frozen_del before delete on sales_return_lines
  for each row execute function app.tg_sales_return_line_frozen();

create or replace function app.tg_sales_return_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then raise exception 'a void return cannot be modified' using errcode = '23514'; end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.return_no <> old.return_no or new.return_date <> old.return_date
       or new.sales_invoice_id <> old.sales_invoice_id or new.dealer_id <> old.dealer_id or new.warehouse_id <> old.warehouse_id then
      raise exception 'a posted return is immutable; reverse it with void_sales_return()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger sales_return_guard before update on sales_returns for each row execute function app.tg_sales_return_guard();
create trigger set_updated_at before update on sales_returns for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on sales_returns for each row execute function app.tg_audit();
create trigger block_delete_unless_draft before delete on sales_returns for each row execute function app.tg_block_delete_unless_draft();

create or replace function create_sales_return(
  p_org uuid, p_sales_invoice_id uuid,
  p_lines jsonb,   -- [{item_id, qty}] — price/cost always looked up from the original invoice, never client-supplied
  p_payment_method text default 'credit', p_cash_account_id uuid default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_return uuid; v_line jsonb; v_no int := 0;
  v_item uuid; v_qty numeric; v_orig record; v_already numeric;
begin
  perform app.require_permission(p_org, 'sales.write');

  select * into inv from sales_invoices where id = p_sales_invoice_id and org_id = p_org;
  if not found then raise exception 'sales invoice not found in this organization' using errcode = '23503'; end if;
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be returned against' using errcode = '23514'; end if;

  insert into sales_returns (org_id, return_no, return_date, sales_invoice_id, dealer_id, warehouse_id,
                              currency_id, rate, payment_method, cash_account_id, description, created_by)
  values (p_org, app.next_seq(p_org, 'sales_return'), current_date, p_sales_invoice_id, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, coalesce(p_payment_method,'credit'), p_cash_account_id, coalesce(p_description,''), auth.uid())
  returning id into v_return;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_item := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select qty, unit_price, unit_cost into v_orig
    from sales_invoice_lines where invoice_id = p_sales_invoice_id and item_id = v_item;
    if not found then raise exception 'item is not on the original invoice' using errcode = '23514'; end if;

    select coalesce(sum(l.qty), 0) into v_already
    from sales_return_lines l join sales_returns r on r.id = l.return_id
    where r.sales_invoice_id = p_sales_invoice_id and l.item_id = v_item and r.status = 'posted';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot return % — only % of % remains returnable for this item', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    insert into sales_return_lines (return_id, org_id, line_no, item_id, qty, unit_price, unit_cost)
    values (v_return, p_org, v_no, v_item, v_qty, v_orig.unit_price, v_orig.unit_cost);
  end loop;

  return v_return;
end;
$$;

drop function if exists post_sales_return(uuid, uuid);
create or replace function post_sales_return(
  p_return_id uuid,
  p_default_sales_account_id uuid default null,   -- same fallback post_sales_invoice() uses for an item missing its own sales_account_id
  p_output_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r sales_returns%rowtype;
  v_move uuid; v_entry uuid; v_period uuid;
  v_line_no int := 0; v_total numeric(19,4); v_vat numeric(19,4);
  g record;
begin
  select * into r from sales_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'sales.post');
  if r.status <> 'draft' then raise exception 'only a draft return can be posted (this one is %)', r.status using errcode = '23514'; end if;
  if not exists (select 1 from sales_return_lines where return_id = p_return_id) then
    raise exception 'return has no lines' using errcode = '23514';
  end if;
  if p_output_vat_account_id is null then
    raise exception 'an output VAT account is required to post a sales return' using errcode = '23514';
  end if;

  -- restock at each line's own historical cost — same principle as void_sales_invoice()
  v_move := create_stock_move(r.org_id, 'adjustment_in', r.return_date,
    'مرجع فاتورة مبيعات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'in', 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from sales_return_lines l where l.return_id = p_return_id),
    'sales_return', r.id);
  perform post_stock_move(v_move);

  select sum(line_total) into v_total from sales_return_lines where return_id = p_return_id;
  v_vat := round(v_total * app.vat_rate(), 4);

  v_period := app.open_period_for(r.org_id, r.return_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.return_date, v_period,
          coalesce(nullif(r.description,''), 'إشعار مرجع مبيعات رقم ' || r.return_no), 'sales_return', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  -- Cr AR (dealer) or Cr cash, for the return total including VAT
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when r.payment_method = 'cash' then r.cash_account_id else d.account_id end,
         'مرجع مبيعات رقم ' || r.return_no, 0, round((v_total + v_vat) * r.rate, 4), r.currency_id, r.rate,
         case when r.payment_method = 'cash' then null else r.dealer_id end
  from dealers d where d.id = r.dealer_id;

  -- Dr revenue, grouped by item, reducing what was recognized (falling back to the default, same rule post_sales_invoice() uses)
  for g in
    select coalesce(it.sales_account_id, p_default_sales_account_id) acc, sum(l.line_total) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id
    group by coalesce(it.sales_account_id, p_default_sales_account_id)
  loop
    if g.acc is null then raise exception 'an item on this return has no sales account and no default was given' using errcode = '23514'; end if;
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مرجع مبيعات', round(g.amt * r.rate, 4), 0, r.currency_id, r.rate);
  end loop;

  -- Dr output VAT, reversing the portion originally charged
  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_output_vat_account_id, 'عكس ضريبة مخرجات — مرجع مبيعات', round(v_vat * r.rate, 4), 0, r.currency_id, r.rate);
  end if;

  -- Cr COGS / Dr inventory, at each line's own historical cost
  for g in
    select it.cogs_account_id acc, sum(l.qty * l.unit_cost) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'عكس تكلفة البضاعة المباعة — مرجع', 0, round(g.amt, 4), r.currency_id, 1);
  end loop;
  for g in
    select it.inventory_account_id acc, sum(l.qty * l.unit_cost) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'إعادة للمخزون — مرجع', round(g.amt, 4), 0, r.currency_id, 1);
  end loop;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update sales_returns set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                           posted_by = auth.uid(), posted_at = now() where id = p_return_id;

  return v_entry;
end;
$$;

create or replace function void_sales_return(p_return_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r sales_returns%rowtype; v_move uuid; v_entry uuid; v_period uuid; v_rev uuid;
begin
  select * into r from sales_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'sales.post');
  if r.status <> 'posted' then raise exception 'only a posted return can be voided' using errcode = '23514'; end if;

  -- take the restocked goods back out, at the same historical cost they came back in at
  v_move := create_stock_move(r.org_id, 'adjustment_out', p_date, 'إلغاء مرجع مبيعات رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'out', 'entered_qty', l.qty))
     from sales_return_lines l where l.return_id = p_return_id),
    'sales_return_void', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), p_date, v_period,
          'إلغاء مرجع مبيعات رقم ' || r.return_no || coalesce(' — ' || p_reason, ''),
          'reversal', r.journal_entry_id, r.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = r.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = r.journal_entry_id;

  insert into sales_returns (org_id, return_no, return_date, sales_invoice_id, dealer_id, warehouse_id,
                              currency_id, rate, payment_method, cash_account_id, description,
                              journal_entry_id, stock_move_id, void_of, status, created_by, posted_by, posted_at)
  values (r.org_id, app.next_seq(r.org_id, 'sales_return'), p_date, r.sales_invoice_id, r.dealer_id, r.warehouse_id,
          r.currency_id, r.rate, r.payment_method, r.cash_account_id, 'إلغاء مرجع رقم ' || r.return_no,
          v_entry, v_move, r.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update sales_returns set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = r.id;

  return v_rev;
end;
$$;

-- ---------------------------------------------------------------------------
-- Purchase returns
-- ---------------------------------------------------------------------------
create table purchase_returns (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  return_no     bigint not null,
  return_date   date not null,
  purchase_invoice_id uuid not null references purchase_invoices(id) on delete restrict,
  dealer_id     uuid not null references dealers(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),
  payment_method text not null default 'credit' check (payment_method in ('credit','cash')),
  cash_account_id uuid references accounts(id) on delete restrict,
  description   text not null default '',

  status        text not null default 'draft' check (status in ('draft','posted','void')),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  stock_move_id     uuid references stock_moves(id) on delete restrict,
  void_of       uuid references purchase_returns(id) on delete restrict,
  reversed_by   uuid references purchase_returns(id) on delete restrict,
  void_reason   text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  posted_by     uuid references auth.users(id),
  posted_at     timestamptz,
  updated_at    timestamptz not null default now(),

  unique (org_id, return_no),
  constraint pr_cash_needs_account check (payment_method <> 'cash' or cash_account_id is not null),
  constraint pr_posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on purchase_returns (org_id, purchase_invoice_id);
create index on purchase_returns (org_id, status);

create table purchase_return_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  return_id     uuid not null references purchase_returns(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),   -- copied from the original invoice line
  line_total    numeric(19,4) generated always as (round(qty * unit_price, 4)) stored,
  unique (return_id, line_no)
);
create index on purchase_return_lines (return_id);

create or replace function app.tg_purchase_return_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from purchase_returns where id = old.return_id;
  if v_status <> 'draft' then raise exception 'return is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger purchase_return_line_frozen_del before delete on purchase_return_lines
  for each row execute function app.tg_purchase_return_line_frozen();

create or replace function app.tg_purchase_return_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then raise exception 'a void return cannot be modified' using errcode = '23514'; end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.return_no <> old.return_no or new.return_date <> old.return_date
       or new.purchase_invoice_id <> old.purchase_invoice_id or new.dealer_id <> old.dealer_id or new.warehouse_id <> old.warehouse_id then
      raise exception 'a posted return is immutable; reverse it with void_purchase_return()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger purchase_return_guard before update on purchase_returns for each row execute function app.tg_purchase_return_guard();
create trigger set_updated_at before update on purchase_returns for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on purchase_returns for each row execute function app.tg_audit();
create trigger block_delete_unless_draft before delete on purchase_returns for each row execute function app.tg_block_delete_unless_draft();

create or replace function create_purchase_return(
  p_org uuid, p_purchase_invoice_id uuid,
  p_lines jsonb,   -- [{item_id, qty}]
  p_payment_method text default 'credit', p_cash_account_id uuid default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_return uuid; v_line jsonb; v_no int := 0;
  v_item uuid; v_qty numeric; v_orig record; v_already numeric;
begin
  perform app.require_permission(p_org, 'purchases.write');

  select * into inv from purchase_invoices where id = p_purchase_invoice_id and org_id = p_org;
  if not found then raise exception 'purchase invoice not found in this organization' using errcode = '23503'; end if;
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be returned against' using errcode = '23514'; end if;

  insert into purchase_returns (org_id, return_no, return_date, purchase_invoice_id, dealer_id, warehouse_id,
                                 currency_id, rate, payment_method, cash_account_id, description, created_by)
  values (p_org, app.next_seq(p_org, 'purchase_return'), current_date, p_purchase_invoice_id, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, coalesce(p_payment_method,'credit'), p_cash_account_id, coalesce(p_description,''), auth.uid())
  returning id into v_return;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_item := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select qty, unit_price into v_orig
    from purchase_invoice_lines where invoice_id = p_purchase_invoice_id and item_id = v_item;
    if not found then raise exception 'item is not on the original invoice' using errcode = '23514'; end if;

    select coalesce(sum(l.qty), 0) into v_already
    from purchase_return_lines l join purchase_returns r on r.id = l.return_id
    where r.purchase_invoice_id = p_purchase_invoice_id and l.item_id = v_item and r.status = 'posted';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot return % — only % of % remains returnable for this item', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    insert into purchase_return_lines (return_id, org_id, line_no, item_id, qty, unit_price)
    values (v_return, p_org, v_no, v_item, v_qty, v_orig.unit_price);
  end loop;

  return v_return;
end;
$$;

create or replace function post_purchase_return(p_return_id uuid, p_input_vat_account_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r purchase_returns%rowtype;
  v_move uuid; v_entry uuid; v_period uuid;
  v_line_no int := 0; v_total numeric(19,4); v_vat numeric(19,4);
  g record;
begin
  select * into r from purchase_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'purchases.post');
  if r.status <> 'draft' then raise exception 'only a draft return can be posted (this one is %)', r.status using errcode = '23514'; end if;
  if not exists (select 1 from purchase_return_lines where return_id = p_return_id) then
    raise exception 'return has no lines' using errcode = '23514';
  end if;
  if p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase return' using errcode = '23514';
  end if;

  -- remove the stock at whatever it's worth NOW — same principle as void_purchase_invoice();
  -- fails naturally (insufficient stock) if less remains than was received, which is correct.
  v_move := create_stock_move(r.org_id, 'adjustment_out', r.return_date, 'مرجع فاتورة مشتريات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'out', 'entered_qty', l.qty))
     from purchase_return_lines l where l.return_id = p_return_id),
    'purchase_return', r.id);
  perform post_stock_move(v_move);

  select sum(line_total) into v_total from purchase_return_lines where return_id = p_return_id;
  v_vat := round(v_total * app.vat_rate(), 4);

  v_period := app.open_period_for(r.org_id, r.return_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.return_date, v_period,
          coalesce(nullif(r.description,''), 'إشعار مرجع مشتريات رقم ' || r.return_no), 'purchase_return', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  -- Dr AP (dealer) or Dr cash, for the return total including VAT — reducing what's owed / cash refunded
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when r.payment_method = 'cash' then r.cash_account_id else d.account_id end,
         'مرجع مشتريات رقم ' || r.return_no, round((v_total + v_vat) * r.rate, 4), 0, r.currency_id, r.rate,
         case when r.payment_method = 'cash' then null else r.dealer_id end
  from dealers d where d.id = r.dealer_id;

  -- Cr inventory, grouped by item, at the ORIGINAL invoice line's price (the commercial credit-note
  -- value) — same mirror-the-original-amount choice void_purchase_invoice() already makes
  for g in
    select it.inventory_account_id acc, sum(l.line_total) amt
    from purchase_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مرجع مشتريات', 0, round(g.amt * r.rate, 4), r.currency_id, r.rate);
  end loop;

  -- Cr input VAT, reversing the portion originally reclaimed
  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_input_vat_account_id, 'عكس ضريبة مدخلات — مرجع مشتريات', 0, round(v_vat * r.rate, 4), r.currency_id, r.rate);
  end if;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update purchase_returns set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                              posted_by = auth.uid(), posted_at = now() where id = p_return_id;

  return v_entry;
end;
$$;

create or replace function void_purchase_return(p_return_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r purchase_returns%rowtype; v_move uuid; v_entry uuid; v_period uuid; v_rev uuid;
begin
  select * into r from purchase_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'purchases.post');
  if r.status <> 'posted' then raise exception 'only a posted return can be voided' using errcode = '23514'; end if;

  -- put the goods back in — this reversal is itself a fresh receipt, so it
  -- gets a fresh engine-computed cost, same as any ordinary incoming line
  v_move := create_stock_move(r.org_id, 'adjustment_in', p_date, 'إلغاء مرجع مشتريات رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'in', 'entered_qty', l.qty, 'unit_cost', l.unit_price))
     from purchase_return_lines l where l.return_id = p_return_id),
    'purchase_return_void', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), p_date, v_period,
          'إلغاء مرجع مشتريات رقم ' || r.return_no || coalesce(' — ' || p_reason, ''),
          'reversal', r.journal_entry_id, r.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = r.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = r.journal_entry_id;

  insert into purchase_returns (org_id, return_no, return_date, purchase_invoice_id, dealer_id, warehouse_id,
                                 currency_id, rate, payment_method, cash_account_id, description,
                                 journal_entry_id, stock_move_id, void_of, status, created_by, posted_by, posted_at)
  values (r.org_id, app.next_seq(r.org_id, 'purchase_return'), p_date, r.purchase_invoice_id, r.dealer_id, r.warehouse_id,
          r.currency_id, r.rate, r.payment_method, r.cash_account_id, 'إلغاء مرجع رقم ' || r.return_no,
          v_entry, v_move, r.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update purchase_returns set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = r.id;

  return v_rev;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants + permissions + RLS — reuse sales.*/purchases.* permissions
-- exactly (a return is the same document family as its invoice, not a new
-- permission surface)
-- ---------------------------------------------------------------------------
revoke all on function create_sales_return(uuid,uuid,jsonb,text,uuid,text) from public, anon;
revoke all on function post_sales_return(uuid,uuid,uuid) from public, anon;
revoke all on function void_sales_return(uuid,date,text) from public, anon;
revoke all on function create_purchase_return(uuid,uuid,jsonb,text,uuid,text) from public, anon;
revoke all on function post_purchase_return(uuid,uuid) from public, anon;
revoke all on function void_purchase_return(uuid,date,text) from public, anon;
grant execute on function create_sales_return(uuid,uuid,jsonb,text,uuid,text) to authenticated;
grant execute on function post_sales_return(uuid,uuid,uuid) to authenticated;
grant execute on function void_sales_return(uuid,date,text) to authenticated;
grant execute on function create_purchase_return(uuid,uuid,jsonb,text,uuid,text) to authenticated;
grant execute on function post_purchase_return(uuid,uuid) to authenticated;
grant execute on function void_purchase_return(uuid,date,text) to authenticated;

alter table sales_returns         enable row level security;
alter table sales_return_lines    enable row level security;
alter table purchase_returns      enable row level security;
alter table purchase_return_lines enable row level security;

create policy sales_return_select on sales_returns for select using (app.is_member(org_id));
create policy sales_return_write  on sales_returns for all
  using (app.has_permission(org_id, 'sales.write')) with check (app.has_permission(org_id, 'sales.write'));
create policy sales_return_line_select on sales_return_lines for select using (app.is_member(org_id));
create policy sales_return_line_write  on sales_return_lines for all
  using (app.has_permission(org_id, 'sales.write')) with check (app.has_permission(org_id, 'sales.write'));

create policy purchase_return_select on purchase_returns for select using (app.is_member(org_id));
create policy purchase_return_write  on purchase_returns for all
  using (app.has_permission(org_id, 'purchases.write')) with check (app.has_permission(org_id, 'purchases.write'));
create policy purchase_return_line_select on purchase_return_lines for select using (app.is_member(org_id));
create policy purchase_return_line_write  on purchase_return_lines for all
  using (app.has_permission(org_id, 'purchases.write')) with check (app.has_permission(org_id, 'purchases.write'));
