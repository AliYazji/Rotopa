-- Sibling of attempt_return_a.sql — see that file's header. Posts "return B" instead.
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000002', false);
set role authenticated;

do $$
declare
  v_return uuid; v_vat_account uuid;
begin
  select v into v_return      from concurrency_handshake where k = 'ret_return_b';
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
