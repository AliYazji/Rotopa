-- ============================================================================
-- Rotopa · Core Stabilization Phase 0 (3/3) — explicit EXECUTE grants for
-- open_cash_shift()/close_cash_shift().
--
-- Every other write-RPC in this project (create_journal_entry,
-- create_voucher, create_sales_invoice, create_dealer, ...) explicitly
-- revokes EXECUTE from public/anon and grants it only to authenticated,
-- on top of (not instead of) their own internal app.require_permission()
-- checks. 20250911003900_cash_shifts.sql defined open_cash_shift()/
-- close_cash_shift() without that pair of statements, leaving them on
-- Postgres's default EXECUTE-granted-to-PUBLIC. Their internal permission
-- checks (cash_shifts.write/cash_shifts.post via app.require_permission)
-- already block anyone without real access, so this is defense-in-depth —
-- restoring the same explicit grant convention every other function in
-- this codebase follows, not a fix for a confirmed exploitable gap.
-- ============================================================================

revoke all on function open_cash_shift(uuid, uuid, jsonb, uuid, text) from public, anon;
grant execute on function open_cash_shift(uuid, uuid, jsonb, uuid, text) to authenticated;

revoke all on function close_cash_shift(uuid, jsonb, uuid, text) from public, anon;
grant execute on function close_cash_shift(uuid, jsonb, uuid, text) to authenticated;
