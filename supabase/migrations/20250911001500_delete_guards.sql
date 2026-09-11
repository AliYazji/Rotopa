-- ============================================================================
-- Rotopa · fix — a posted/void document could be deleted outright
--
-- Every "posted document" table (journal_entries, vouchers, cheques,
-- stock_moves, sales_invoices) already blocks UPDATE once posted
-- (tg_*_guard, before update). None of them blocked DELETE — a client
-- holding the ordinary *.write permission (needed for perfectly normal
-- draft editing) could DELETE a posted row directly over the API and erase
-- it, lines and all, with no trace beyond audit_log. Immutability that only
-- covers UPDATE isn't immutability.
--
-- Drafts remain freely deletable (discarding an abandoned draft — e.g. one
-- left behind by a posting attempt that failed on insufficient stock — is
-- exactly the cleanup a user needs, see docs/data-model.md module 10).
-- cheques has no 'draft' state at all — its untouched starting state is
-- 'in_hand' (nothing has posted yet, same as a draft everywhere else); every
-- other cheque status already reflects a real transition, so it goes
-- through cancel_cheque()/bounce_cheque() instead of a silent delete.
-- ============================================================================

create or replace function app.tg_block_delete_unless_draft()
returns trigger language plpgsql as $$
declare v_deletable boolean;
begin
  v_deletable := case when tg_table_name = 'cheques' then old.status = 'in_hand' else old.status = 'draft' end;
  if not v_deletable then
    raise exception '% % is % and cannot be deleted — use void/cancel instead', tg_table_name, old.id, old.status
      using errcode = '23514';
  end if;
  return old;
end;
$$;

create trigger block_delete_unless_draft before delete on journal_entries  for each row execute function app.tg_block_delete_unless_draft();
create trigger block_delete_unless_draft before delete on vouchers        for each row execute function app.tg_block_delete_unless_draft();
create trigger block_delete_unless_draft before delete on cheques         for each row execute function app.tg_block_delete_unless_draft();
create trigger block_delete_unless_draft before delete on stock_moves     for each row execute function app.tg_block_delete_unless_draft();
create trigger block_delete_unless_draft before delete on sales_invoices  for each row execute function app.tg_block_delete_unless_draft();
