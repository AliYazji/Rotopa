-- ============================================================================
-- Rotopa · Executive review remediation, Package 2 (1/2) — freeze the tax
-- actually charged onto the document itself; stop re-deriving historical
-- tax from the org's CURRENT setting.
--
-- ROOT CAUSE: neither sales_invoices/sales_invoice_lines nor
-- purchase_invoices/purchase_invoice_lines ever stored the rate/amount of
-- VAT actually applied at posting time. post_sales_invoice()/
-- post_purchase_invoice() compute v_vat locally and post it as a
-- journal_lines row, then discard the local variable — nothing survives on
-- the document. Every screen that needs "how much tax was on this
-- invoice" (SalesInvoiceDetail.tsx, PrintInvoice.tsx via taxRate/taxEnabled
-- from useOrg()) re-multiplies the invoice's CURRENT line totals by
-- whatever the ORG'S TAX SETTING IS RIGHT NOW — if that setting changes
-- after the invoice was posted (rate edited, tax disabled), every old
-- invoice's displayed/printed tax retroactively changes to match the NEW
-- setting, which is not what was actually charged or recorded in the
-- ledger. Worse: post_sales_return()/post_purchase_return() ALSO
-- recompute VAT via a fresh app.vat_rate(org_id) call at return-post time
-- (20250911003500_configurable_tax.sql:385,480) — a return posted after
-- the org's rate changed reverses the WRONG amount of VAT relative to what
-- the original sale/purchase actually charged.
--
-- FIX: sales_invoices/purchase_invoices gain tax_rate (the fraction
-- actually applied) + tax_amount (the actual amount, in the document's own
-- currency, pre-rate — same convention as line_total); the *_lines tables
-- gain tax_rate too (same value as the header — tax in this system is a
-- single uniform org-wide rate applied to the whole document, not
-- per-line/per-item, so there is nothing additional to store per line
-- beyond the rate that was in force; taxable_base is already line_total,
-- which was already stored). Populated by post_sales_invoice()/
-- post_purchase_invoice() at posting time. sales_returns/purchase_returns
-- gain the same two header columns, and post_sales_return()/
-- post_purchase_return() now compute their own VAT from the ORIGINAL
-- invoice's STORED tax_rate (round(return_total * original.tax_rate, 4) —
-- deterministic, single rounding step, no dependency on the org's current
-- setting) instead of a fresh app.vat_rate() call.
--
-- Inclusive/exclusive tax mode and a distinct tax "code" are not part of
-- this fix: this system has never supported either (one flat exclusive
-- rate, org-wide, no per-item exemption) — nothing to snapshot that
-- doesn't already reduce to tax_rate/tax_amount.
--
-- BACKFILL, investigated before writing (not guessed): every already-
-- posted invoice's actual VAT is still a real, immutable fact in its own
-- posted journal_lines — post_sales_invoice()/post_purchase_invoice()
-- have used the exact same journal-line description
-- ('ضريبة قيمة مضافة على المبيعات' / 'ضريبة قيمة مضافة على المشتريات')
-- for VAT since the feature was first built (20250911002000_vat.sql),
-- unchanged through every later redefinition — grepped and confirmed
-- identical wording in all 5 historical bodies of post_sales_invoice and
-- all 4 of post_purchase_invoice. The backfill below reads that real GL
-- line (converted back from base currency via the invoice's own stored
-- `rate`, an exact inverse, not an estimate) rather than reapplying any
-- rate — for an invoice where tax was disabled at posting time (no VAT
-- line exists at all, since the insert was itself conditional on
-- v_vat > 0), tax_amount correctly backfills to 0, which is exactly what
-- was actually charged. The same reasoning and description-matching
-- applies to sales_returns/purchase_returns' own reversal VAT lines
-- ('عكس ضريبة مخرجات — مرجع مبيعات' / 'عكس ضريبة مدخلات — مرجع مشتريات').
-- No case was found where the historical rate could NOT be reconstructed
-- exactly from stored data — every posted document's own ledger already
-- carries the real number.
-- ============================================================================

alter table sales_invoices      add column tax_rate   numeric(9,6)  not null default 0;
alter table sales_invoices      add column tax_amount numeric(19,4) not null default 0;
alter table sales_invoice_lines add column tax_rate   numeric(9,6)  not null default 0;

alter table purchase_invoices      add column tax_rate   numeric(9,6)  not null default 0;
alter table purchase_invoices      add column tax_amount numeric(19,4) not null default 0;
alter table purchase_invoice_lines add column tax_rate   numeric(9,6)  not null default 0;

alter table sales_returns    add column tax_rate   numeric(9,6)  not null default 0;
alter table sales_returns    add column tax_amount numeric(19,4) not null default 0;
alter table purchase_returns add column tax_rate   numeric(9,6)  not null default 0;
alter table purchase_returns add column tax_amount numeric(19,4) not null default 0;

comment on column sales_invoices.tax_rate is
  'The VAT fraction actually applied when this invoice was posted (frozen — never re-derived from the org''s current tax setting).';
comment on column sales_invoices.tax_amount is
  'The VAT amount actually charged when this invoice was posted, in the invoice''s own currency (pre-rate, same convention as line_total).';

-- ---------------------------------------------------------------------------
-- Backfill already-posted documents from their own real, immutable
-- journal_lines — see header for why this is a reconstruction of stored
-- fact, not a guess.
--
-- Every one of these tables has its own "posted is immutable" guard
-- trigger (app.tg_sales_invoice_guard, app.tg_purchase_invoice_guard,
-- app.tg_sales_return_guard, app.tg_purchase_return_guard on the headers;
-- app.tg_sales_invoice_line_validate / app.tg_purchase_invoice_line_validate
-- on the invoice lines, which block UPDATE once the parent is no longer
-- 'draft') — entirely correct application behavior, and exactly why this
-- backfill cannot just run as a normal UPDATE: caught live, running this
-- migration against a database seeded with a real historical posted
-- invoice, which is exactly the scenario this backfill exists for.
-- Disabling each guard for the duration of this one-time, superuser-run
-- migration (never something application code or an authenticated client
-- can do) is the standard, narrowly-scoped way to backfill a column on an
-- otherwise-immutable-by-design table.
-- ---------------------------------------------------------------------------
alter table sales_invoices         disable trigger sales_invoice_guard;
alter table sales_invoice_lines    disable trigger sales_invoice_line_validate;
alter table purchase_invoices      disable trigger purchase_invoice_guard;
alter table purchase_invoice_lines disable trigger purchase_invoice_line_validate;
alter table sales_returns          disable trigger sales_return_guard;
alter table purchase_returns       disable trigger purchase_return_guard;

with totals as (
  select si.id, coalesce(sum(sil.line_total), 0) as v_total
  from sales_invoices si
  left join sales_invoice_lines sil on sil.invoice_id = si.id
  where si.status in ('posted', 'void')
  group by si.id
),
vat_lines as (
  select si.id, round(coalesce(sum(jl.credit), 0) / si.rate, 4) as v_vat
  from sales_invoices si
  join journal_lines jl on jl.entry_id = si.journal_entry_id and jl.description = 'ضريبة قيمة مضافة على المبيعات'
  where si.status in ('posted', 'void')
  group by si.id, si.rate
)
update sales_invoices si
set tax_amount = coalesce(v.v_vat, 0),
    tax_rate   = case when t.v_total > 0 then round(coalesce(v.v_vat, 0) / t.v_total, 6) else 0 end
from totals t
left join vat_lines v on v.id = t.id
where si.id = t.id;

update sales_invoice_lines sil
set tax_rate = si.tax_rate
from sales_invoices si
where si.id = sil.invoice_id and si.status in ('posted', 'void');

with totals as (
  select pi.id, coalesce(sum(pil.line_total), 0) as v_total
  from purchase_invoices pi
  left join purchase_invoice_lines pil on pil.invoice_id = pi.id
  where pi.status in ('posted', 'void')
  group by pi.id
),
vat_lines as (
  select pi.id, round(coalesce(sum(jl.debit), 0) / pi.rate, 4) as v_vat
  from purchase_invoices pi
  join journal_lines jl on jl.entry_id = pi.journal_entry_id and jl.description = 'ضريبة قيمة مضافة على المشتريات'
  where pi.status in ('posted', 'void')
  group by pi.id, pi.rate
)
update purchase_invoices pi
set tax_amount = coalesce(v.v_vat, 0),
    tax_rate   = case when t.v_total > 0 then round(coalesce(v.v_vat, 0) / t.v_total, 6) else 0 end
from totals t
left join vat_lines v on v.id = t.id
where pi.id = t.id;

update purchase_invoice_lines pil
set tax_rate = pi.tax_rate
from purchase_invoices pi
where pi.id = pil.invoice_id and pi.status in ('posted', 'void');

with totals as (
  select sr.id, coalesce(sum(srl.line_total), 0) as v_total
  from sales_returns sr
  left join sales_return_lines srl on srl.return_id = sr.id
  where sr.status in ('posted', 'void')
  group by sr.id
),
vat_lines as (
  select sr.id, round(coalesce(sum(jl.debit), 0) / sr.rate, 4) as v_vat
  from sales_returns sr
  join journal_lines jl on jl.entry_id = sr.journal_entry_id and jl.description = 'عكس ضريبة مخرجات — مرجع مبيعات'
  where sr.status in ('posted', 'void')
  group by sr.id, sr.rate
)
update sales_returns sr
set tax_amount = coalesce(v.v_vat, 0),
    tax_rate   = case when t.v_total > 0 then round(coalesce(v.v_vat, 0) / t.v_total, 6) else 0 end
from totals t
left join vat_lines v on v.id = t.id
where sr.id = t.id;

with totals as (
  select pr.id, coalesce(sum(prl.line_total), 0) as v_total
  from purchase_returns pr
  left join purchase_return_lines prl on prl.return_id = pr.id
  where pr.status in ('posted', 'void')
  group by pr.id
),
vat_lines as (
  select pr.id, round(coalesce(sum(jl.credit), 0) / pr.rate, 4) as v_vat
  from purchase_returns pr
  join journal_lines jl on jl.entry_id = pr.journal_entry_id and jl.description = 'عكس ضريبة مدخلات — مرجع مشتريات'
  where pr.status in ('posted', 'void')
  group by pr.id, pr.rate
)
update purchase_returns pr
set tax_amount = coalesce(v.v_vat, 0),
    tax_rate   = case when t.v_total > 0 then round(coalesce(v.v_vat, 0) / t.v_total, 6) else 0 end
from totals t
left join vat_lines v on v.id = t.id
where pr.id = t.id;

alter table sales_invoices         enable trigger sales_invoice_guard;
alter table sales_invoice_lines    enable trigger sales_invoice_line_validate;
alter table purchase_invoices      enable trigger purchase_invoice_guard;
alter table purchase_invoice_lines enable trigger purchase_invoice_line_validate;
alter table sales_returns          enable trigger sales_return_guard;
alter table purchase_returns       enable trigger purchase_return_guard;

-- ---------------------------------------------------------------------------
-- post_sales_invoice() — same signature as 20250911003500_configurable_tax.sql,
-- body-only change: now writes tax_rate/tax_amount onto the header and
-- tax_rate onto every line, alongside the existing journal_lines VAT entry.
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
  v_rate numeric(9,6);
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
  v_rate := app.vat_rate(inv.org_id);
  v_vat := round(v_total * v_rate, 4);
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

  -- freeze the tax actually applied onto the document and its lines
  update sales_invoices set tax_rate = v_rate, tax_amount = v_vat where id = p_invoice_id;
  update sales_invoice_lines set tax_rate = v_rate where invoice_id = p_invoice_id;

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
-- post_purchase_invoice() — same signature/body shape as post_sales_invoice()'s
-- change above.
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
  v_rate numeric(9,6);
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
  v_rate := app.vat_rate(inv.org_id);
  v_vat := round(v_total * v_rate, 4);
  if v_vat > 0 and p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase invoice' using errcode = '23514';
  end if;

  update purchase_invoices set tax_rate = v_rate, tax_amount = v_vat where id = p_invoice_id;
  update purchase_invoice_lines set tax_rate = v_rate where invoice_id = p_invoice_id;

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

grant execute on function post_sales_invoice(uuid, uuid, uuid) to authenticated;
grant execute on function post_purchase_invoice(uuid, uuid) to authenticated;
