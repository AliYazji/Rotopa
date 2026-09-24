-- One concurrent attempt to POST the pre-created "return A" 8-unit draft
-- against a 10-unit invoice line (attempt_return_b.sql posts the OTHER
-- 8-unit draft against the SAME line at the same time — 16 > 10, only one
-- may legitimately succeed). Prints exactly one line:
--   RESULT: success | RESULT: over_return | RESULT: OTHER_ERROR: <msg>
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000002', false);
set role authenticated;

do $$
declare
  v_return uuid; v_vat_account uuid;
begin
  select v into v_return      from concurrency_handshake where k = 'ret_return_a';
  select v into v_vat_account from concurrency_handshake where k = 'ret_vat_account_id';

  begin
    perform post_sales_return(v_return, p_output_vat_account_id := v_vat_account);
    raise notice 'RESULT: success';
  exception
    when sqlstate '23514' then
      raise notice 'RESULT: over_return';
    when others then
      raise notice 'RESULT: OTHER_ERROR: %', sqlerrm;
  end;
end $$;
