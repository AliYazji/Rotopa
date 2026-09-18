-- ============================================================================
-- Rotopa · Core Stabilization Phase 0 (6/6) — a holder of gl.create alone
-- could bypass post_journal_entry()/void_journal_entry() entirely via a
-- direct UPDATE on journal_entries.
--
-- ROOT CAUSE: `je_write` was a single FOR ALL policy gated only on
-- gl.create, covering insert/update/delete with no awareness of `status`
-- at all:
--
--   create policy je_write on journal_entries for all
--     using (app.has_permission(org_id, 'gl.create'))
--     with check (app.has_permission(org_id, 'gl.create'));
--
-- The trigger app.tg_journal_entry_guard() (unchanged, still in force)
-- stops a VOID entry from being touched at all, and stops a POSTED entry
-- from becoming anything but VOID with every other column identical — but
-- it never checks WHO is making the change or WHICH permission they hold,
-- and it never verifies that a real, balanced reversing entry was created
-- alongside a posted->void transition. Combined, a member holding only
-- gl.create (no gl.post, no gl.void) could, entirely outside
-- post_journal_entry()/void_journal_entry():
--   - `update journal_entries set status='posted', posted_by=auth.uid(),
--     posted_at=now() where id=<their own draft>` — skipping gl.post and
--     the fiscal-period-open check inside post_journal_entry().
--   - `update journal_entries set status='void' where id=<their own
--     draft>` — an undefined, never-meant-to-exist state transition.
--   - `update journal_entries set status='void' where id=<any posted
--     entry in their org>` — skipping gl.void AND, critically, leaving
--     reversed_by NULL with no reversing journal_lines ever created: the
--     entry now reads as "voided" everywhere but its debit/credit effect
--     never actually reversed. This got strictly more dangerous once
--     20250911004500 made every report count status IN ('posted','void')
--     — the numbers wouldn't even visibly change, masking that the
--     ledger's void/reversed_by invariant had been broken by hand.
--
-- FIX: split je_write into per-operation policies whose USING/WITH CHECK
-- clauses key on `status`, not just permission — the simplest fix that
-- doesn't depend on the UI at all (RLS is enforced server-side regardless
-- of what any client sends):
--   - insert: only status='draft' rows, with gl.create.
--   - update: OLD row must already be status='draft' (so a posted/void
--     row is never even reachable for a direct UPDATE — RLS filters it
--     out before app.tg_journal_entry_guard() ever runs), AND the NEW row
--     must also be status='draft' (so a direct UPDATE can never itself
--     carry the row across a status boundary).
--   - delete: only status='draft' rows.
-- Every status TRANSITION (draft->posted, posted->void) is consequently
-- only reachable through post_journal_entry()/void_journal_entry(), which
-- both run SECURITY DEFINER as the table owner — RLS does not apply to
-- them at all, so they are completely unaffected by this change (verified
-- live, not just assumed, in 400_journal_status_transition_security.sql).
-- journal_lines' own policy/triggers (app.tg_journal_line_validate/
-- app.tg_journal_line_frozen, which already require the referencing
-- entry to be 'draft' for any line insert/update/delete) were already
-- correct and are untouched.
-- ============================================================================

drop policy if exists je_write on journal_entries;

create policy je_insert on journal_entries for insert
  with check (app.has_permission(org_id, 'gl.create') and status = 'draft');

create policy je_update on journal_entries for update
  using (app.has_permission(org_id, 'gl.create') and status = 'draft')
  with check (app.has_permission(org_id, 'gl.create') and status = 'draft');

create policy je_delete on journal_entries for delete
  using (app.has_permission(org_id, 'gl.create') and status = 'draft');
