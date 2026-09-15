-- Concurrency test fixture: one org, one item with EXACTLY 10 units on
-- hand at one warehouse. Two concurrent attempts will each try to take 8
-- (16 > 10 total) — only one may succeed if stock locking is real.
--
-- IDs are handed to the two concurrent attempt scripts via a small
-- handshake table (not bash variable-passing across docker exec calls —
-- far more robust) that setup.sql, in_hand_move.sql and the verify step
-- all read/write directly against the same database.
\set ON_ERROR_STOP on

create table if not exists concurrency_handshake (k text primary key, v uuid);
truncate concurrency_handshake;

insert into auth.users (id, email) values ('c0000000-0000-0000-0000-000000000001','concurrency@test')
  on conflict (id) do nothing;
-- is_local=false (not true): this script has no explicit begin/commit, so
-- every top-level statement is its own autocommitted transaction — a
-- LOCAL setting would vanish before the very next statement. Session-scope
-- (false) persists for the rest of this one psql connection, same as the
-- plain `set role` right below it.
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000001', false);
set role authenticated;

do $$
declare
  v_org uuid; v_parent uuid; v_inv uuid; v_cogs uuid; v_equity uuid; v_wh uuid; v_item uuid;
begin
  v_org := create_organization('CONCORG','مؤسسة اختبار التزامن','NIS','شيكل',1);
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','b',v_parent,true,'debit') returning id into v_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','c',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','d',v_parent,true,'credit') returning id into v_equity;
  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'w') returning id into v_wh;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id)
  values (v_org, 'SKU-RACE', 'صنف اختبار تزامن', v_inv, v_cogs) returning id into v_item;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 10, 'unit_cost', 1))),
    v_equity);

  insert into concurrency_handshake (k, v) values ('org_id', v_org), ('item_id', v_item), ('warehouse_id', v_wh);
end $$;

select k, v from concurrency_handshake order by k;
