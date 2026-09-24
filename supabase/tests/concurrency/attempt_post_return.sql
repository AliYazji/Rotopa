-- One side of the void-vs-return race (see setup_void_vs_return.sql):
-- posts the pre-created draft return. Prints exactly one line:
--   RESULT: success | RESULT: rejected | RESULT: OTHER_ERROR: <msg>
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000003', false);
set role authenticated;

do $$
declare
  v_return uuid; v_vat_account uuid;
begin
  select v into v_return      from concurrency_handshake where k = 'vr_return_id';
  select v into v_vat_account from concurrency_handshake where k = 'vr_vat_account_id';

  begin
    perform post_sales_return(v_return, p_output_vat_account_id := v_vat_account);
    raise notice 'RESULT: success';
  exception
    when sqlstate '23514' then
      raise notice 'RESULT: rejected';
    when others then
      raise notice 'RESULT: OTHER_ERROR: %', sqlerrm;
  end;
end $$;
