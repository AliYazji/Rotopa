-- ============================================================================
-- Rotopa · fix — void_stock_move() was referenced but never implemented
--
-- tg_stock_move_guard's error message already told the caller to "reverse it
-- with void_stock_move()" (module 09) — the function didn't exist. Every
-- other posted-document table (journal_entries, vouchers, cheques,
-- sales_invoices) has a real void_*; stock_moves was the one gap.
--
-- Reverses every line by flipping its direction in place (same item, same
-- warehouse) rather than swapping warehouses on a transfer's two legs — this
-- also makes a transfer reversal correct for free: post_stock_move()'s own
-- transfer-cost-inheritance rule (an 'in' line's cost comes from this same
-- move's 'out' lines) naturally uses "whatever the far side is worth now"
-- symmetrically in both directions, so it needs no special-casing here.
-- A reversed 'out' line (originally computed by the engine) is passed back
-- in at its ORIGINAL historical cost — restocking at what it actually left
-- at, same principle as void_sales_invoice(). A reversed 'in' line becomes
-- an 'out' with no cost supplied, same as any ordinary outgoing line: the
-- engine computes it from the current average at posting time.
-- ============================================================================

create or replace function void_stock_move(p_move_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  m stock_moves%rowtype;
  v_rev uuid;
  v_entry uuid;
  v_period uuid;
  l record;
  v_line_no int := 0;
begin
  select * into m from stock_moves where id = p_move_id for update;
  if not found then raise exception 'move not found' using errcode = 'P0002'; end if;
  perform app.require_permission(m.org_id, 'inventory.post');
  if m.status <> 'posted' then
    raise exception 'only a posted move can be voided' using errcode = '23514';
  end if;

  insert into stock_moves (org_id, move_no, move_date, move_type, description, source_type, void_of, created_by)
  values (m.org_id, app.next_seq(m.org_id, 'stock_move_' || m.move_type), p_date, m.move_type,
          'إلغاء حركة رقم ' || m.move_no || coalesce(' — ' || p_reason, ''), 'stock_move_void', m.id, auth.uid())
  returning id into v_rev;

  for l in select * from stock_move_lines where move_id = p_move_id order by line_no loop
    v_line_no := v_line_no + 1;
    insert into stock_move_lines (move_id, line_no, item_id, warehouse_id, direction, unit_id, entered_qty, base_qty, unit_cost)
    values (
      v_rev, v_line_no, l.item_id, l.warehouse_id,
      case when l.direction = 'in' then 'out' else 'in' end,
      l.unit_id, l.entered_qty, l.base_qty,
      case when l.direction = 'out' then l.unit_cost else null end
    );
  end loop;

  -- Mirror the original's GL entry (if it had one — p_contra_account_id was
  -- given at post time) and attach it to v_rev BEFORE posting v_rev: once
  -- post_stock_move() flips it to 'posted', tg_stock_move_guard forbids any
  -- further UPDATE to the row other than the eventual posted->void move —
  -- setting journal_entry_id afterward would hit that guard.
  if m.journal_entry_id is not null then
    v_period := app.open_period_for(m.org_id, p_date);
    insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                  source_type, source_id, created_by)
    values (m.org_id, app.next_seq(m.org_id, 'journal'), p_date, v_period,
            'إلغاء حركة مخزون رقم ' || m.move_no || coalesce(' — ' || p_reason, ''),
            'reversal', m.journal_entry_id, auth.uid())
    returning id into v_entry;

    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate
    from journal_lines where entry_id = m.journal_entry_id;

    update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
    update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = m.journal_entry_id;
    update stock_moves set journal_entry_id = v_entry where id = v_rev;   -- v_rev is still draft here
  end if;

  perform post_stock_move(v_rev);

  update stock_moves set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = m.id;

  return v_rev;
end;
$$;

revoke all on function void_stock_move(uuid, date, text) from public, anon;
grant execute on function void_stock_move(uuid, date, text) to authenticated;
