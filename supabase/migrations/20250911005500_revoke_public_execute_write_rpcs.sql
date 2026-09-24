-- ============================================================================
-- Rotopa · Post-review hardening — no write RPC exposed through PostgREST
-- (public schema) may still carry Postgres's default PUBLIC execute grant.
--
-- FOUND while auditing post_purchase_return()'s own grants (executive review
-- follow-up): every comparable write RPC already had PUBLIC correctly
-- revoked (post_sales_invoice, post_purchase_invoice, void_journal_entry,
-- post_payroll_run, void_sales_invoice, post_purchase_return, ...) — except
-- create_sales_invoice(), which has carried Postgres's implicit
-- "CREATE FUNCTION grants EXECUTE to PUBLIC by default" grant since it was
-- first written, apparently missed by every later revision. This does not
-- bypass app.require_permission()'s own internal authorization check (a
-- caller still needs real org membership + the right permission to succeed),
-- but relying solely on that inner check instead of also narrowing the
-- outer PostgREST-level grant is exactly the inconsistency the review asked
-- to close — defense in depth, not defense in one layer only.
--
-- Also tightened for the same reason, even though the `app` schema is
-- internal (not exposed to PostgREST's HTTP surface, so these are not
-- reachable the same way create_sales_invoice was): every SECURITY DEFINER
-- helper in `app` that still carried a PUBLIC grant. A direct Postgres
-- session authenticated as `authenticated`/`anon` (bypassing PostgREST
-- entirely) could otherwise still invoke them — narrowing this costs
-- nothing (every real caller goes through the public-schema RPCs, which
-- already have their own correct grants) and removes that residual surface.
-- ============================================================================

revoke all on function create_sales_invoice(uuid, date, uuid, uuid, jsonb, uuid, numeric, text, uuid, text, date, uuid) from public;
grant execute on function create_sales_invoice(uuid, date, uuid, uuid, jsonb, uuid, numeric, text, uuid, text, date, uuid) to authenticated;

revoke all on function app.apply_entry_to_balances(uuid, integer) from public;
revoke all on function app.assert_not_last_active_owner(uuid) from public;
revoke all on function app.seed_coa_manufacturing(uuid) from public;
revoke all on function app.seed_default_chart_of_accounts(uuid) from public;
revoke all on function app.post_cheque_entry(cheques, date, uuid, boolean, text) from public;
