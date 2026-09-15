-- One concurrent attempt to sell 8 units from the 10-unit fixture stock.
-- Run this file from TWO psql processes launched at the same time — only
-- one should ever succeed (8+8=16 > 10). Prints exactly one line:
--   RESULT: success  |  RESULT: insufficient_stock  |  RESULT: OTHER_ERROR: <msg>
-- is_local=false — see setup.sql's comment on the same line
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000001', false);
set role authenticated;

do $$
declare
  v_org uuid; v_item uuid; v_wh uuid; v_move uuid;
begin
  select v into v_org  from concurrency_handshake where k = 'org_id';
  select v into v_item from concurrency_handshake where k = 'item_id';
  select v into v_wh   from concurrency_handshake where k = 'warehouse_id';

  begin
    v_move := create_stock_move(v_org, 'adjustment_out', current_date, 'محاولة بيع متزامنة',
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'out', 'entered_qty', 8)));
    perform post_stock_move(v_move);
    raise notice 'RESULT: success';
  exception
    when sqlstate '23514' then
      raise notice 'RESULT: insufficient_stock';
    when others then
      raise notice 'RESULT: OTHER_ERROR: %', sqlerrm;
  end;
end $$;
