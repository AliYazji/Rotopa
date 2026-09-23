-- ============================================================================
-- Rotopa · Executive review remediation, Package 4 — void_journal_entry()
-- must only reverse genuine manual entries.
--
-- ROOT CAUSE: void_journal_entry() (20250911000600_general_ledger.sql) never
-- checked source_type at all — only that the caller holds gl.void and the
-- entry is status='posted'. It would happily void a 'sales_invoice',
-- 'purchase_invoice', 'sales_return', 'purchase_return', 'receipt_voucher'/
-- 'payment_voucher', 'payroll_run', or 'stock_move'-sourced entry directly,
-- reversing only the GL side — the owning document (sales_invoices.status,
-- purchase_invoices.status, cash_shifts, payroll_runs, ...) stays 'posted'
-- forever while its own journal_entries row says 'void': a permanent split
-- between the document and its ledger, plus none of the document-specific
-- side effects (restocking, AR/AP reversal, cash-shift/payroll consistency)
-- that the real void_sales_invoice()/void_purchase_invoice()/etc. RPCs
-- perform.
--
-- FIX: void_journal_entry() now rejects any entry whose source_type is not
-- 'manual' — "only reverse genuine manual entries", per the review's own
-- wording. This includes 'reversal' entries too: every module void
-- (void_sales_invoice, void_purchase_return, void_journal_entry itself,
-- ...) already creates its own 'reversal'-sourced entry as a byproduct of
-- voiding the OWNING document, and updates that document's own status —
-- there is no scenario where directly re-voiding a bare reversal entry
-- through this generic RPC is the correct operation, so it is refused with
-- the same clear message.
--
-- Also closes a related gap the same review flagged: while an entry is
-- still 'draft', RLS (je_update) only requires status='draft' on both
-- sides of the UPDATE — it says nothing about source_type/source_id, so a
-- client holding gl.create could freely relabel a draft's source_type/
-- source_id after create_journal_entry() already created it (the existing
-- unique(org_id, source_type, source_id) constraint already blocks
-- impersonating an EXISTING document's real entry, since that pair is
-- already taken — but it does nothing to stop relabeling into a made-up,
-- non-colliding source_type/source_id). app.tg_journal_entry_guard() only
-- protected source_type/source_id once a row reached status='posted'.
-- Extended here to make both columns write-once for every row, regardless
-- of status: settable only at INSERT time (by create_journal_entry() or
-- any module RPC), never changeable by a later UPDATE at all.
-- ============================================================================

create or replace function void_journal_entry(p_entry_id uuid, p_date date, p_reason text)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  e journal_entries%rowtype;
  v_rev uuid;
begin
  select * into e from journal_entries where id = p_entry_id for update;
  if not found then raise exception 'entry not found' using errcode = 'P0002'; end if;
  perform app.require_permission(e.org_id, 'gl.void');
  if e.status <> 'posted' then
    raise exception 'only a posted entry can be voided' using errcode = '23514';
  end if;

  if e.source_type <> 'manual' then
    raise exception 'this entry is linked to an operational document (%) and cannot be voided directly here — void that document instead / لا يمكن إلغاء هذا القيد مباشرة لأنه مرتبط بمستند تشغيلي (%)، يجب إلغاء المستند نفسه من الشاشة الخاصة به', e.source_type, e.source_type
      using errcode = '23514';
  end if;

  insert into journal_entries (
    org_id, entry_no, entry_date, fiscal_period_id, branch_id, description,
    source_type, source_id, document_currency_id, void_of, created_by
  ) values (
    e.org_id, app.next_seq(e.org_id, 'journal'), p_date,
    app.open_period_for(e.org_id, p_date), e.branch_id,
    'إلغاء قيد رقم ' || e.entry_no || coalesce(' — ' || p_reason, ''),
    'reversal', e.id, e.document_currency_id, e.id, auth.uid()
  ) returning id into v_rev;

  insert into journal_lines (
    entry_id, line_no, account_id, description,
    debit, credit, currency_id, rate, fc_debit, fc_credit,
    dealer_id, cost_center_id, department_id, fund_id, project_id, budget_id
  )
  select v_rev, line_no, account_id, 'عكس: ' || description,
         credit, debit, currency_id, rate, fc_credit, fc_debit,
         dealer_id, cost_center_id, department_id, fund_id, project_id, budget_id
  from journal_lines where entry_id = e.id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_rev;
  update journal_entries set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = e.id;

  return v_rev;
end;
$$;

-- source_type/source_id become write-once (INSERT-time only) for every
-- row, not just once posted -- the posted-only column-invariant list is
-- unchanged for every OTHER column (still only enforced once posted).
create or replace function app.tg_journal_entry_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then
    raise exception 'a void entry cannot be modified' using errcode = '23514';
  end if;

  if new.source_type <> old.source_type or new.source_id is distinct from old.source_id then
    raise exception 'source_type/source_id are set once at creation and cannot be changed afterward' using errcode = '23514';
  end if;

  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id            <> old.org_id
       or new.entry_no          <> old.entry_no
       or new.entry_date        <> old.entry_date
       or new.fiscal_period_id  <> old.fiscal_period_id
       or new.description       <> old.description
       or new.branch_id         is distinct from old.branch_id
       or new.document_currency_id is distinct from old.document_currency_id
       or new.is_opening        <> old.is_opening
       or new.posted_by         is distinct from old.posted_by
       or new.posted_at         is distinct from old.posted_at then
      raise exception 'a posted entry is immutable; reverse it with void_journal_entry()' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;
