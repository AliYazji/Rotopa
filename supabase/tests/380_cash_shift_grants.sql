-- Regression coverage for 20250911004300_cash_shift_grants.sql.
--
-- Before this fix, open_cash_shift()/close_cash_shift() had no explicit
-- REVOKE/GRANT at all, leaving them on Postgres's default EXECUTE-granted-
-- to-PUBLIC (which anon inherits) — unlike every other write-RPC in this
-- project. Defense-in-depth, not a confirmed exploit (their internal
-- app.require_permission() checks already block real access), but this
-- proves the explicit grant now matches the rest of the codebase.
\set ON_ERROR_STOP on
begin;

do $$
begin
  assert not has_function_privilege('anon', 'open_cash_shift(uuid,uuid,jsonb,uuid,text)', 'EXECUTE'),
    'anon should not have EXECUTE on open_cash_shift';
  assert has_function_privilege('authenticated', 'open_cash_shift(uuid,uuid,jsonb,uuid,text)', 'EXECUTE'),
    'authenticated should have EXECUTE on open_cash_shift';

  assert not has_function_privilege('anon', 'close_cash_shift(uuid,jsonb,uuid,text)', 'EXECUTE'),
    'anon should not have EXECUTE on close_cash_shift';
  assert has_function_privilege('authenticated', 'close_cash_shift(uuid,jsonb,uuid,text)', 'EXECUTE'),
    'authenticated should have EXECUTE on close_cash_shift';

  raise notice 'CASH SHIFT GRANTS OK';
end $$;

rollback;
