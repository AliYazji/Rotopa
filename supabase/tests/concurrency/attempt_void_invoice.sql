-- Other side of the void-vs-return race (see setup_void_vs_return.sql):
-- voids the invoice the draft return references. Prints exactly one line:
--   RESULT: success | RESULT: rejected | RESULT: OTHER_ERROR: <msg>
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000003', false);
set role authenticated;

do $$
declare
  v_invoice uuid;
begin
  select v into v_invoice from concurrency_handshake where k = 'vr_invoice_id';

  begin
    perform void_sales_invoice(v_invoice, current_date, 'محاولة إلغاء متزامنة');
    raise notice 'RESULT: success';
  exception
    when sqlstate '23514' then
      raise notice 'RESULT: rejected';
    when others then
      raise notice 'RESULT: OTHER_ERROR: %', sqlerrm;
  end;
end $$;
