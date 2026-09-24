-- Regression coverage for 20250911004900_return_line_caps.sql.
--
-- Before this fix, sales_return_lines/purchase_return_lines only ever
-- referenced (invoice_id, item_id) — never the specific invoice LINE — so
-- two lines of the same invoice selling the same item pooled their
-- returnable quantity together (and the original line's price/cost was
-- picked ambiguously). The over-return cap was also only ever checked at
-- create_sales_return()/create_purchase_return() (draft-creation) time,
-- never re-checked at post_*_return() time — the real commit point — so
-- two drafts each within the single-line cap could both post and
-- together exceed it. (The genuinely concurrent version of that exact
-- race is covered separately, with real OS-level concurrency, in
-- supabase/tests/concurrency/run.sh's second scenario — this file covers
-- the sequential/deterministic scenarios instead.)
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-0015-000000000001','owner@returncaps.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-0015-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('RETCAPORG','مؤسسة اختبار سقف المرتجعات')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_rev uuid; v_inv_acc uuid; v_cogs uuid; v_vat_out uuid; v_cust_ctrl uuid;
  v_wh uuid; v_item uuid; v_cust uuid;
  v_invoice uuid; v_line1 uuid; v_line2 uuid;
  v_return_a uuid; v_return_b uuid; v_return_dup uuid;
  v_caught boolean; v_msg text;
  r record;
begin
  select id into v_cash    from accounts where org_id = v_org and code = '11101';
  select id into v_rev     from accounts where org_id = v_org and code = '61101';
  select id into v_inv_acc from accounts where org_id = v_org and code = '11601';
  select id into v_cogs    from accounts where org_id = v_org and code = '51101';
  select id into v_vat_out from accounts where org_id = v_org and code = '31401';
  select id into v_cust_ctrl from accounts where org_id = v_org and code = '11501';

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'المستودع الرئيسي') returning id into v_wh;
  v_cust := create_dealer(v_org, 'عميل اختبار', v_cust_ctrl, p_is_customer := true);
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'RETCAPSKU', 'صنف اختبار', v_inv_acc, v_cogs, v_rev, 50)
  returning id into v_item;
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1000, 'unit_cost', 10))),
    (select id from accounts where org_id = v_org and code = '41001'));

  -- =========================================================================
  -- 1) same item on TWO different invoice lines (different prices) — the
  --    cap must track each line independently, not pool by item_id
  -- =========================================================================
  v_invoice := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(
      jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 50),
      jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 45)
    ));
  perform post_sales_invoice(v_invoice, p_output_vat_account_id := v_vat_out);
  select id into v_line1 from sales_invoice_lines where invoice_id = v_invoice and unit_price = 50;
  select id into v_line2 from sales_invoice_lines where invoice_id = v_invoice and unit_price = 45;
  assert v_line1 <> v_line2, 'the two lines should be genuinely distinct rows';

  -- fully return line 1 (10 units) — must not affect line 2's own cap at all
  v_return_a := create_sales_return(v_org, v_invoice,
    jsonb_build_array(jsonb_build_object('invoice_line_id', v_line1, 'qty', 10)));
  assert (select unit_price from sales_return_lines where return_id = v_return_a) = 50,
    'the return line should pick up line 1''s own price (50), not line 2''s (45)';
  perform post_sales_return(v_return_a, p_output_vat_account_id := v_vat_out);

  -- line 2 should still have its FULL 10 units returnable — proves the
  -- cap is per-line, not pooled by item_id (the old bug would have left
  -- only 0 remaining here, since line 1's 10 would have counted against
  -- the shared item-level pool)
  v_return_b := create_sales_return(v_org, v_invoice,
    jsonb_build_array(jsonb_build_object('invoice_line_id', v_line2, 'qty', 10)));
  assert (select unit_price from sales_return_lines where return_id = v_return_b) = 45,
    'the return line should pick up line 2''s own price (45)';
  perform post_sales_return(v_return_b, p_output_vat_account_id := v_vat_out);

  -- and line 1 must reject any further return — it's fully returned already
  v_caught := false;
  begin
    perform create_sales_return(v_org, v_invoice, jsonb_build_array(jsonb_build_object('invoice_line_id', v_line1, 'qty', 1)));
  exception when sqlstate '23514' then v_caught := true;
  end;
  assert v_caught, 'line 1 should reject any further return — it is already fully returned';

  -- =========================================================================
  -- 2) duplicate lines within ONE return pointing at the SAME source
  --    line must be summed together and capped correctly at post time
  -- =========================================================================
  declare v_invoice2 uuid; v_invoice2_line uuid; v_dup_return uuid; begin
    v_invoice2 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 20)));
    perform post_sales_invoice(v_invoice2, p_output_vat_account_id := v_vat_out);
    v_invoice2_line := (select id from sales_invoice_lines where invoice_id = v_invoice2);

    -- two separate {invoice_line_id, qty} entries for the SAME line in one
    -- create call, 6+6=12 > 10. create_sales_return()'s own per-entry
    -- check only ever compares against OTHER already-POSTED returns (by
    -- design — it cannot see its own still-draft, same-call insertions),
    -- so this succeeds at CREATE time; it is post_sales_return()'s new
    -- grouped re-check (group by source line, sum this return's own
    -- lines together) that must catch it at the real commit point.
    declare v_overdup uuid; begin
      v_overdup := create_sales_return(v_org, v_invoice2, jsonb_build_array(
        jsonb_build_object('invoice_line_id', v_invoice2_line, 'qty', 6),
        jsonb_build_object('invoice_line_id', v_invoice2_line, 'qty', 6)
      ));
      v_caught := false;
      begin
        perform post_sales_return(v_overdup, p_output_vat_account_id := v_vat_out);
      exception when sqlstate '23514' then v_caught := true;
      end;
      assert v_caught, 'posting a return whose own duplicate lines against one source line sum past what was sold should be rejected';
      assert (select status from sales_returns where id = v_overdup) = 'draft', 'the rejected over-duplicate return should remain a draft';
    end;

    -- a valid duplicate (4+4=8, within the 10 available) should succeed,
    -- and post_sales_return's grouped re-check should see it as ONE
    -- combined 8, not two independent 4s each individually "under cap"
    v_dup_return := create_sales_return(v_org, v_invoice2, jsonb_build_array(
      jsonb_build_object('invoice_line_id', v_invoice2_line, 'qty', 4),
      jsonb_build_object('invoice_line_id', v_invoice2_line, 'qty', 4)
    ));
    assert (select count(*) from sales_return_lines where return_id = v_dup_return) = 2, 'both duplicate lines should be stored';
    perform post_sales_return(v_dup_return, p_output_vat_account_id := v_vat_out);
    assert (select sum(qty) from sales_return_lines srl join sales_returns sr on sr.id = srl.return_id
            where srl.sales_invoice_line_id = v_invoice2_line and sr.status = 'posted') = 8,
      'the combined posted returned quantity for this line should be exactly 8';

    -- now only 2 remain (10 - 8) — a further return of 3 must be rejected
    v_caught := false;
    begin
      perform create_sales_return(v_org, v_invoice2, jsonb_build_array(jsonb_build_object('invoice_line_id', v_invoice2_line, 'qty', 3)));
    exception when sqlstate '23514' then v_caught := true;
    end;
    assert v_caught, 'only 2 of 10 should remain returnable after the combined 8 already posted';
  end;

  -- =========================================================================
  -- 3) sequential (non-concurrent) proof that post_sales_return() itself
  --    re-checks the cap, not just create_sales_return() at draft time:
  --    two drafts each within the per-draft cap, but together over the
  --    line's total — the SECOND one to POST (not create) must fail
  -- =========================================================================
  declare v_invoice3 uuid; v_invoice3_line uuid; v_draft1 uuid; v_draft2 uuid; begin
    v_invoice3 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 30)));
    perform post_sales_invoice(v_invoice3, p_output_vat_account_id := v_vat_out);
    v_invoice3_line := (select id from sales_invoice_lines where invoice_id = v_invoice3);

    -- both drafts for 6 each are individually valid at CREATE time (6 <= 10,
    -- and neither counts the other since neither is posted yet)
    v_draft1 := create_sales_return(v_org, v_invoice3, jsonb_build_array(jsonb_build_object('invoice_line_id', v_invoice3_line, 'qty', 6)));
    v_draft2 := create_sales_return(v_org, v_invoice3, jsonb_build_array(jsonb_build_object('invoice_line_id', v_invoice3_line, 'qty', 6)));

    -- post the first — succeeds (6 <= 10)
    perform post_sales_return(v_draft1, p_output_vat_account_id := v_vat_out);
    assert (select status from sales_returns where id = v_draft1) = 'posted';

    -- posting the SECOND must now fail — 6 (already posted) + 6 (this one) = 12 > 10.
    -- This is the exact scenario the old code could not catch: draft2 passed
    -- its OWN create-time check (nothing was posted yet when it was created).
    v_caught := false; v_msg := null;
    begin
      perform post_sales_return(v_draft2, p_output_vat_account_id := v_vat_out);
    exception when sqlstate '23514' then
      v_caught := true;
      get stacked diagnostics v_msg = message_text;
    end;
    assert v_caught, 'posting the second draft should be rejected — the FIRST draft''s post already consumed the line''s remaining cap';
    assert v_msg ilike '%returnable%' or v_msg ilike '%another return%', 'the rejection should explain the cap was exceeded, got: ' || coalesce(v_msg, '<null>');
    assert (select status from sales_returns where id = v_draft2) = 'draft', 'the rejected second draft should remain a draft, not silently posted';
  end;

  raise notice 'RETURN LINE CAPS OK';
end $$;

rollback;
