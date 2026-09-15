-- ============================================================================
-- Rotopa · Module 17 (continued) — configurable, toggleable tax rate
--
-- app.vat_rate() has been a hardcoded 16% constant since module 17 (own
-- comment: "One place to change if that becomes necessary" — it became
-- necessary; the user asked directly for a way to edit/enable/disable it).
-- Stored per-org in the existing org_settings key/value table (same table
-- this session's "print" settings already uses — no new table needed),
-- key='tax', value={enabled: boolean, rate: numeric}.
--
-- SAME "grep every later create-or-replace, build from the true latest"
-- discipline this continuation already had to learn twice: post_sales_
-- invoice/post_purchase_invoice/post_sales_return/post_purchase_return each
-- redefined by 20250911002600_multi_uom_invoicing.sql (confirmed the last
-- one before this file for all four) — every body below is copied from
-- THAT migration, not from vat.sql/returns.sql where they were first
-- written, with only the tax handling changed.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- app.vat_rate(p_org) — was 0-arg / hardcoded. Reads org_settings; a
-- missing row (an org that existed before this migration and never opened
-- the new settings page) defaults to the exact old constant (16%, enabled)
-- so behavior never silently changes for anyone already relying on it.
-- Disabling tax sets the EFFECTIVE rate to 0 without losing the configured
-- rate value itself, so re-enabling later restores it exactly.
-- ---------------------------------------------------------------------------
create or replace function app.vat_rate(p_org uuid) returns numeric
language sql stable as $$
  select case when coalesce((value->>'enabled')::boolean, true)
              then coalesce((value->>'rate')::numeric, 0.16)
              else 0
         end
  from org_settings where org_id = p_org and key = 'tax'
  union all select 0.16   -- fallback row if org_settings has no 'tax' key yet
  limit 1;
$$;
comment on function app.vat_rate(uuid) is
  'Per-organization VAT rate, editable/toggleable from /settings (org_settings key=''tax''). Effective rate is 0 when disabled.';

-- seed today's real behavior explicitly for every existing org, so the new
-- settings page shows something real immediately instead of an empty state
insert into org_settings (org_id, key, value)
select id, 'tax', jsonb_build_object('enabled', true, 'rate', 0.16) from organizations
on conflict (org_id, key) do nothing;

-- future orgs get the same default from day one
create or replace function create_organization(
  p_code text,
  p_name_ar text,
  p_base_currency_code text default 'NIS',
  p_base_currency_name_ar text default 'شيكل',
  p_fiscal_year_start_month int default 1
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_org uuid;
  v_cur uuid;
  v_role_owner uuid;
  v_role_acct  uuid;
  v_role_view  uuid;
  k text;
begin
  if auth.uid() is null then
    raise exception 'must be signed in to create an organization' using errcode = '42501';
  end if;

  insert into organizations (code, name_ar, fiscal_year_start_month)
  values (p_code, p_name_ar, p_fiscal_year_start_month)
  returning id into v_org;

  insert into currencies (org_id, code, name_ar, is_base, decimal_places)
  values (v_org, p_base_currency_code, p_base_currency_name_ar, true, 2)
  returning id into v_cur;

  update organizations set base_currency_id = v_cur where id = v_org;

  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', true, 'rate', 0.16));

  -- roles
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'owner',      'مالك',   true) returning id into v_role_owner;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'accountant', 'محاسب',  true) returning id into v_role_acct;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'viewer',     'مطّلع',  true) returning id into v_role_view;

  perform set_config('app.skip_role_guard', 'on', true);
  insert into role_permissions (role_id, permission_key)
    select v_role_owner, key from permissions;
  insert into role_permissions (role_id, permission_key)
    select v_role_acct, key from permissions
    where key not in ('org.manage','roles.write','members.write');
  insert into role_permissions (role_id, permission_key) values
    (v_role_view, 'audit.read'), (v_role_view, 'reports.view');
  perform set_config('app.skip_role_guard', 'off', true);

  insert into memberships (org_id, user_id, role_id, is_owner)
  values (v_org, auth.uid(), v_role_owner, true);

  perform create_fiscal_year(v_org, extract(year from now())::int);

  return v_org;
end;
$$;

-- ---------------------------------------------------------------------------
-- post_sales_invoice() — same as 20250911003400_composite_items.sql's
-- version (VAT + multi-UOM + composite items all still intact), with two
-- tax changes: app.vat_rate(inv.org_id) instead of app.vat_rate(), and the
-- output-VAT-account requirement now conditional on v_vat > 0 (moved after
-- v_total/v_vat are computed — both only need sales_invoice_lines, not the
-- stock move, so this stays fail-fast, no side effects before the check).
-- ---------------------------------------------------------------------------
create or replace function post_sales_invoice(
  p_invoice_id uuid,
  p_default_sales_account_id uuid default null,
  p_output_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_total numeric(19,4) := 0;
  v_vat numeric(19,4);
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
  if exists (
    select 1 from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id and it.is_composite
      and not exists (select 1 from bom_lines b where b.finished_item_id = it.id)
  ) then
    raise exception 'a composite item on this invoice has no recipe (bom_lines) defined' using errcode = '23514';
  end if;
  if exists (
    select 1 from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id and it.is_composite and it.cogs_account_id is null
  ) then
    raise exception 'a composite item on this invoice has no COGS account set' using errcode = '23514';
  end if;

  select sum(line_total) into v_total from sales_invoice_lines where invoice_id = p_invoice_id;
  v_vat := round(v_total * app.vat_rate(inv.org_id), 4);
  if v_vat > 0 and p_output_vat_account_id is null then
    raise exception 'an output VAT account is required to post a sales invoice' using errcode = '23514';
  end if;

  update sales_invoice_lines sil set unit_cost = sub.unit_cost
  from (
    select l.id, sum(b.qty * coalesce(iwb.avg_cost, 0)) as unit_cost
    from sales_invoice_lines l
    join items it on it.id = l.item_id
    join bom_lines b on b.finished_item_id = l.item_id
    left join item_warehouse_balances iwb on iwb.item_id = b.component_item_id and iwb.warehouse_id = inv.warehouse_id
    where l.invoice_id = p_invoice_id and it.is_composite
    group by l.id, l.base_qty
  ) sub
  where sil.id = sub.id;

  v_move := create_stock_move(inv.org_id, 'sale_out', inv.invoice_date,
    'فاتورة مبيعات رقم ' || inv.invoice_no,
    (
      select jsonb_agg(x) from (
        select jsonb_build_object('item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
                                   'direction', 'out', 'unit_id', l.unit_id, 'entered_qty', l.qty) as x
        from sales_invoice_lines l join items it on it.id = l.item_id
        where l.invoice_id = p_invoice_id and not it.is_composite
        union all
        select jsonb_build_object('item_id', b.component_item_id, 'warehouse_id', inv.warehouse_id,
                                   'direction', 'out', 'entered_qty', b.qty * l.base_qty) as x
        from sales_invoice_lines l join items it on it.id = l.item_id
        join bom_lines b on b.finished_item_id = l.item_id
        where l.invoice_id = p_invoice_id and it.is_composite
      ) combined
    ),
    'sales_invoice', inv.id);
  perform post_stock_move(v_move);

  update sales_invoice_lines sil
    set unit_cost = sml.unit_cost
  from stock_move_lines sml, items it
  where sml.move_id = v_move and sml.item_id = sil.item_id and sil.invoice_id = p_invoice_id
    and it.id = sil.item_id and not it.is_composite;

  v_period := app.open_period_for(inv.org_id, inv.invoice_date);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مبيعات رقم ' || inv.invoice_no),
          'sales_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مبيعات رقم ' || inv.invoice_no, round((v_total + v_vat) * inv.rate, 4), 0, inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

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

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_output_vat_account_id, 'ضريبة قيمة مضافة على المبيعات', 0, round(v_vat * inv.rate, 4), inv.currency_id, inv.rate);
  end if;

  for g in
    select it.cogs_account_id acc, sum(l.base_qty * l.unit_cost) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'تكلفة البضاعة المباعة', round(g.amt, 4), 0, inv.currency_id, 1);
  end loop;

  for g in
    select acc, sum(amt) amt from (
      select it.inventory_account_id acc, l.base_qty * l.unit_cost amt
      from sales_invoice_lines l join items it on it.id = l.item_id
      where l.invoice_id = p_invoice_id and not it.is_composite
      union all
      select ci.inventory_account_id acc, b.qty * l.base_qty * coalesce(iwb.avg_cost, 0) amt
      from sales_invoice_lines l join items it on it.id = l.item_id
      join bom_lines b on b.finished_item_id = l.item_id
      join items ci on ci.id = b.component_item_id
      left join item_warehouse_balances iwb on iwb.item_id = b.component_item_id and iwb.warehouse_id = inv.warehouse_id
      where l.invoice_id = p_invoice_id and it.is_composite
    ) x
    group by acc
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

-- ---------------------------------------------------------------------------
-- post_purchase_invoice() — same as multi_uom_invoicing.sql's version, tax
-- changes only.
-- ---------------------------------------------------------------------------
create or replace function post_purchase_invoice(p_invoice_id uuid, p_input_vat_account_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_total numeric(19,4) := 0;
  v_vat numeric(19,4);
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

  select sum(line_total) into v_total from purchase_invoice_lines where invoice_id = p_invoice_id;
  v_vat := round(v_total * app.vat_rate(inv.org_id), 4);
  if v_vat > 0 and p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase invoice' using errcode = '23514';
  end if;

  v_move := create_stock_move(inv.org_id, 'purchase_in', inv.invoice_date,
    'فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'unit_id', l.unit_id, 'entered_qty', l.qty,
        'unit_cost', round(l.line_total / l.base_qty, 4)))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice', inv.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(inv.org_id, inv.invoice_date);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مشتريات رقم ' || inv.invoice_no),
          'purchase_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

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

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_input_vat_account_id, 'ضريبة قيمة مضافة على المشتريات', round(v_vat * inv.rate, 4), 0, inv.currency_id, inv.rate);
  end if;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مشتريات رقم ' || inv.invoice_no, 0, round((v_total + v_vat) * inv.rate, 4), inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update purchase_invoices set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                               posted_by = auth.uid(), posted_at = now()
    where id = p_invoice_id;

  return v_entry;
end;
$$;

-- ---------------------------------------------------------------------------
-- post_sales_return() — same as multi_uom_invoicing.sql's version, tax
-- changes only.
-- ---------------------------------------------------------------------------
create or replace function post_sales_return(
  p_return_id uuid,
  p_default_sales_account_id uuid default null,
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

  select sum(line_total) into v_total from sales_return_lines where return_id = p_return_id;
  v_vat := round(v_total * app.vat_rate(r.org_id), 4);
  if v_vat > 0 and p_output_vat_account_id is null then
    raise exception 'an output VAT account is required to post a sales return' using errcode = '23514';
  end if;

  v_move := create_stock_move(r.org_id, 'adjustment_in', r.return_date,
    'مرجع فاتورة مبيعات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'in', 'unit_id', l.unit_id, 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from sales_return_lines l where l.return_id = p_return_id),
    'sales_return', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, r.return_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.return_date, v_period,
          coalesce(nullif(r.description,''), 'إشعار مرجع مبيعات رقم ' || r.return_no), 'sales_return', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when r.payment_method = 'cash' then r.cash_account_id else d.account_id end,
         'مرجع مبيعات رقم ' || r.return_no, 0, round((v_total + v_vat) * r.rate, 4), r.currency_id, r.rate,
         case when r.payment_method = 'cash' then null else r.dealer_id end
  from dealers d where d.id = r.dealer_id;

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

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_output_vat_account_id, 'عكس ضريبة مخرجات — مرجع مبيعات', round(v_vat * r.rate, 4), 0, r.currency_id, r.rate);
  end if;

  for g in
    select it.cogs_account_id acc, sum(l.base_qty * l.unit_cost) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'عكس تكلفة البضاعة المباعة — مرجع', 0, round(g.amt, 4), r.currency_id, 1);
  end loop;
  for g in
    select it.inventory_account_id acc, sum(l.base_qty * l.unit_cost) amt
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

-- ---------------------------------------------------------------------------
-- post_purchase_return() — same as multi_uom_invoicing.sql's version, tax
-- changes only.
-- ---------------------------------------------------------------------------
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

  select sum(line_total) into v_total from purchase_return_lines where return_id = p_return_id;
  v_vat := round(v_total * app.vat_rate(r.org_id), 4);
  if v_vat > 0 and p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase return' using errcode = '23514';
  end if;

  v_move := create_stock_move(r.org_id, 'adjustment_out', r.return_date, 'مرجع فاتورة مشتريات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'out', 'unit_id', l.unit_id, 'entered_qty', l.qty))
     from purchase_return_lines l where l.return_id = p_return_id),
    'purchase_return', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, r.return_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.return_date, v_period,
          coalesce(nullif(r.description,''), 'إشعار مرجع مشتريات رقم ' || r.return_no), 'purchase_return', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when r.payment_method = 'cash' then r.cash_account_id else d.account_id end,
         'مرجع مشتريات رقم ' || r.return_no, round((v_total + v_vat) * r.rate, 4), 0, r.currency_id, r.rate,
         case when r.payment_method = 'cash' then null else r.dealer_id end
  from dealers d where d.id = r.dealer_id;

  for g in
    select it.inventory_account_id acc, sum(l.line_total) amt
    from purchase_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مرجع مشتريات', 0, round(g.amt * r.rate, 4), r.currency_id, r.rate);
  end loop;

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
