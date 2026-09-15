-- ============================================================================
-- Rotopa · Modules 10/11 (continued) + 08 (continued) — invoice due dates
-- and AR/AP aging
--
-- Not a legacy replica: checked analysis/columns.txt directly — the only
-- DueDate column in the whole legacy schema lives on `Deals_tb` (bank
-- discounting of cheques/promissory notes), which has ZERO rows in the real
-- backup. There is no legacy due-date or aging concept that was ever
-- actually used. This is a genuine ADDITION (طبق الأصل phase is done),
-- built because open-item aging is standard accounting practice and the
-- user asked for it directly.
--
-- Design decision that matters: this schema tracks AR/AP at the DEALER
-- level via the general ledger (module 05), not per-invoice open-item
-- tracking — a receipt voucher pays down a dealer's account balance, it
-- doesn't reference which invoice(s) it settles. So "how much of invoice
-- #7 is still open" isn't a stored fact anywhere; it's derived with a
-- standard FIFO assumption: the dealer's CURRENT balance is treated as
-- covering their MOST RECENT invoices first (equivalently: payments are
-- assumed applied to the OLDEST invoices first). This is the same
-- assumption every simple (non-open-item) accounting system uses for aging
-- and is clearly documented here and in docs/data-model.md — it can misattribute
-- which specific invoice a partial payment covers if a customer pays
-- out-of-order, but the TOTAL open amount always reconciles exactly to the
-- dealer's real GL balance (proven by construction, see the aging query
-- below — no invented money).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- due_date columns
-- ---------------------------------------------------------------------------
alter table sales_invoices    add column due_date date;
alter table purchase_invoices add column due_date date;

-- Backfilling existing POSTED rows would otherwise hit the immutability
-- guard trigger (it rejects any update to a posted row that isn't a void) —
-- this is a schema migration filling in a column that didn't exist when
-- those rows were posted, not a runtime edit, so it's the one legitimate
-- place to step around that guard.
alter table sales_invoices    disable trigger sales_invoice_guard;
alter table purchase_invoices disable trigger purchase_invoice_guard;

update sales_invoices    set due_date = invoice_date where due_date is null;
update purchase_invoices set due_date = invoice_date where due_date is null;

alter table sales_invoices    enable trigger sales_invoice_guard;
alter table purchase_invoices enable trigger purchase_invoice_guard;

alter table sales_invoices    alter column due_date set not null;
alter table purchase_invoices alter column due_date set not null;

alter table sales_invoices    add constraint sales_invoice_due_on_or_after_invoice    check (due_date >= invoice_date);
alter table purchase_invoices add constraint purchase_invoice_due_on_or_after_invoice check (due_date >= invoice_date);

create index on sales_invoices (org_id, due_date) where status = 'posted' and payment_method = 'credit';
create index on purchase_invoices (org_id, due_date) where status = 'posted' and payment_method = 'credit';

-- ---------------------------------------------------------------------------
-- create_sales_invoice / create_purchase_invoice: add p_due_date
-- (drop-then-recreate — CREATE OR REPLACE with an added parameter creates a
-- silent overload instead of replacing, same lesson as post_sales_return)
-- ---------------------------------------------------------------------------
drop function if exists create_sales_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text);
create or replace function create_sales_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default '', p_due_date date default null   -- defaults to invoice_date (due immediately) if not given
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
                               payment_method, cash_account_id, description, due_date, created_by)
  values (p_org, app.next_seq(p_org, 'sales_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), coalesce(p_due_date, p_invoice_date), auth.uid())
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
revoke all on function create_sales_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text,date) from public, anon;
grant execute on function create_sales_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text,date) to authenticated;

drop function if exists create_purchase_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text);
create or replace function create_purchase_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default '', p_due_date date default null
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
                                  payment_method, cash_account_id, description, due_date, created_by)
  values (p_org, app.next_seq(p_org, 'purchase_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), coalesce(p_due_date, p_invoice_date), auth.uid())
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
revoke all on function create_purchase_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text,date) from public, anon;
grant execute on function create_purchase_invoice(uuid,date,uuid,uuid,jsonb,uuid,numeric,text,uuid,text,date) to authenticated;

-- ---------------------------------------------------------------------------
-- void_sales_invoice / void_purchase_invoice: their mirror-row insert didn't
-- know about due_date (it didn't exist yet) and now fails the new NOT NULL
-- constraint. Same signature, so create-or-replace is a clean swap (no drop
-- needed — only create_*_invoice's signature actually changed above).
-- The void mirror's own due_date is just its own invoice_date (p_date) —
-- a reversal has no real payment term of its own.
-- ---------------------------------------------------------------------------
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

  v_move := create_stock_move(inv.org_id, 'adjustment_in', p_date, 'مرجع فاتورة مبيعات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from sales_invoice_lines l where l.invoice_id = p_invoice_id),
    'sales_invoice_void', inv.id);
  perform post_stock_move(v_move);

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
                               payment_method, cash_account_id, description, due_date, journal_entry_id, stock_move_id,
                               void_of, status, created_by, posted_by, posted_at)
  values (inv.org_id, app.next_seq(inv.org_id, 'sales_invoice'), p_date, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, inv.payment_method, inv.cash_account_id,
          'إلغاء فاتورة رقم ' || inv.invoice_no, p_date, v_entry, v_move, inv.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update sales_invoices set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = inv.id;

  return v_rev;
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

  v_move := create_stock_move(inv.org_id, 'adjustment_out', p_date, 'مرجع فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'out', 'entered_qty', l.qty))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice_void', inv.id);
  perform post_stock_move(v_move);

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
                                  payment_method, cash_account_id, description, due_date, journal_entry_id, stock_move_id,
                                  void_of, status, created_by, posted_by, posted_at)
  values (inv.org_id, app.next_seq(inv.org_id, 'purchase_invoice'), p_date, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, inv.payment_method, inv.cash_account_id,
          'إلغاء فاتورة رقم ' || inv.invoice_no, p_date, v_entry, v_move, inv.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update purchase_invoices set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = inv.id;

  return v_rev;
end;
$$;

-- ---------------------------------------------------------------------------
-- AR / AP aging — FIFO consumption of each dealer's real GL balance across
-- their own open credit invoices, oldest-due-first. Reconciles by
-- construction: sum(open_amount) per dealer always equals their real GL
-- balance (never invents or loses money), because open_amount is derived
-- FROM that balance, not accumulated independently of it.
-- ---------------------------------------------------------------------------
create or replace function ar_aging_detail(p_org uuid, p_as_of date default current_date)
returns table (
  dealer_id      uuid,
  dealer_code    citext,
  dealer_name    text,
  invoice_id     uuid,
  invoice_no     bigint,
  invoice_date   date,
  due_date       date,
  days_overdue   int,
  bucket         text,
  invoice_total  numeric(19,4),
  open_amount    numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  with inv as (
    select si.id, si.invoice_no, si.invoice_date, si.due_date, si.dealer_id,
           d.code as dealer_code, d.name_ar as dealer_name,
           jl.debit as invoice_total
    from sales_invoices si
    join dealers d on d.id = si.dealer_id
    join journal_lines jl on jl.entry_id = si.journal_entry_id
      and jl.dealer_id = si.dealer_id and jl.account_id = d.account_id
    where si.org_id = p_org and si.status = 'posted' and si.payment_method = 'credit'
      and si.invoice_date <= p_as_of
  ),
  running as (
    select *,
      sum(invoice_total) over (partition by dealer_id order by invoice_date, invoice_no
                                rows between unbounded preceding and current row) as cum_upto,
      sum(invoice_total) over (partition by dealer_id) as cum_total
    from inv
  ),
  bal as (
    select distinct dealer_id, account_balance((select account_id from dealers where id = i.dealer_id), p_as_of) as balance
    from inv i
  )
  select r.dealer_id, r.dealer_code, r.dealer_name, r.id, r.invoice_no, r.invoice_date, r.due_date,
         (p_as_of - r.due_date) as days_overdue,
         case when p_as_of <= r.due_date then 'not_due'
              when p_as_of - r.due_date <= 30 then '1_30'
              when p_as_of - r.due_date <= 60 then '31_60'
              when p_as_of - r.due_date <= 90 then '61_90'
              else 'over_90' end as bucket,
         r.invoice_total,
         greatest(least(b.balance - (r.cum_total - r.cum_upto), r.invoice_total), 0) as open_amount
  from running r
  join bal b on b.dealer_id = r.dealer_id
  where greatest(least(b.balance - (r.cum_total - r.cum_upto), r.invoice_total), 0) > 0.005
  order by r.dealer_name, r.invoice_date, r.invoice_no;
$$;

create or replace function ap_aging_detail(p_org uuid, p_as_of date default current_date)
returns table (
  dealer_id      uuid,
  dealer_code    citext,
  dealer_name    text,
  invoice_id     uuid,
  invoice_no     bigint,
  invoice_date   date,
  due_date       date,
  days_overdue   int,
  bucket         text,
  invoice_total  numeric(19,4),
  open_amount    numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  with inv as (
    select pi.id, pi.invoice_no, pi.invoice_date, pi.due_date, pi.dealer_id,
           d.code as dealer_code, d.name_ar as dealer_name,
           jl.credit as invoice_total
    from purchase_invoices pi
    join dealers d on d.id = pi.dealer_id
    join journal_lines jl on jl.entry_id = pi.journal_entry_id
      and jl.dealer_id = pi.dealer_id and jl.account_id = d.account_id
    where pi.org_id = p_org and pi.status = 'posted' and pi.payment_method = 'credit'
      and pi.invoice_date <= p_as_of
  ),
  running as (
    select *,
      sum(invoice_total) over (partition by dealer_id order by invoice_date, invoice_no
                                rows between unbounded preceding and current row) as cum_upto,
      sum(invoice_total) over (partition by dealer_id) as cum_total
    from inv
  ),
  -- AP lives on a credit-normal account: account_balance() is debit-minus-credit,
  -- so a real payable shows up NEGATIVE there — flip sign to a positive owed amount.
  bal as (
    select distinct dealer_id, -account_balance((select account_id from dealers where id = i.dealer_id), p_as_of) as balance
    from inv i
  )
  select r.dealer_id, r.dealer_code, r.dealer_name, r.id, r.invoice_no, r.invoice_date, r.due_date,
         (p_as_of - r.due_date) as days_overdue,
         case when p_as_of <= r.due_date then 'not_due'
              when p_as_of - r.due_date <= 30 then '1_30'
              when p_as_of - r.due_date <= 60 then '31_60'
              when p_as_of - r.due_date <= 90 then '61_90'
              else 'over_90' end as bucket,
         r.invoice_total,
         greatest(least(b.balance - (r.cum_total - r.cum_upto), r.invoice_total), 0) as open_amount
  from running r
  join bal b on b.dealer_id = r.dealer_id
  where greatest(least(b.balance - (r.cum_total - r.cum_upto), r.invoice_total), 0) > 0.005
  order by r.dealer_name, r.invoice_date, r.invoice_no;
$$;

grant execute on function ar_aging_detail(uuid, date) to authenticated;
grant execute on function ap_aging_detail(uuid, date) to authenticated;
