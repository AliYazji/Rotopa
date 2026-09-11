-- Fixed assets: register posts Dr asset/Cr credit account, depreciation runs
-- (single + capped + rejected-too-soon), disposal at gain/loss/exact book
-- value, immutability + permanent-delete guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f1000000-0000-0000-0000-000000000001','assets@test');
select set_config('request.jwt.claim.sub','f1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('FAORG','مؤسسة اختبار الأصول','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_asset_acc uuid; v_accum_acc uuid; v_dep_exp_acc uuid; v_cash uuid; v_gainloss uuid;
  v_asset1 uuid; v_asset2 uuid; v_asset3 uuid; v_entry uuid;
  v_year int;
begin
  -- fixed dates (2025) so the depreciation-schedule math below is
  -- deterministic — create_organization() only auto-creates the CURRENT
  -- year's fiscal periods, so open every year this test's dates touch
  -- (skipping whichever one create_organization already made).
  for v_year in 2025..2031 loop
    begin
      perform create_fiscal_year(v_org, v_year);
    exception when unique_violation then null;
    end;
  end loop;

  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'FA','أصول ثابتة',v_parent,true,'debit') returning id into v_asset_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'ACCDEP','مجمع إهلاك',v_parent,true,'credit') returning id into v_accum_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'DEPEXP','مصروف إهلاك',v_parent,true,'debit') returning id into v_dep_exp_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','الصندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'GL','أرباح/خسائر استبعاد',v_parent,true,'credit') returning id into v_gainloss;

  -- 1) register: cost 12000, salvage 0, 12 months -> Dr FA 12000 / Cr cash 12000
  v_asset1 := register_fixed_asset(v_org, 'A1', 'سيارة', v_asset_acc, v_accum_acc, v_dep_exp_acc,
    '2025-01-01'::date, 12000, 0, 12, v_cash);
  assert account_balance(v_asset_acc) = 12000, 'asset account should be debited 12000';
  assert account_balance(v_cash) = -12000, 'cash should be credited 12000';
  assert (select status from fixed_assets where id = v_asset1) = 'active', 'should be active';

  -- 2) first depreciation run 2 months later -> 2 x 1000 = 2000
  v_entry := post_depreciation(v_asset1, '2025-03-01'::date);
  assert (select accumulated_depreciation from fixed_assets where id = v_asset1) = 2000, 'should accumulate 2000 (2 months x 1000)';
  assert account_balance(v_dep_exp_acc) = 2000, 'depreciation expense should be debited 2000';
  assert account_balance(v_accum_acc) = -2000, 'accumulated depreciation should be credited 2000';
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'depreciation entry must balance';

  -- 3) running again immediately (same date) is rejected — nothing new elapsed
  begin
    perform post_depreciation(v_asset1, '2025-03-01'::date);
    raise exception 'TEST FAIL: re-ran depreciation with no new elapsed time';
  exception when sqlstate '23514' then null;
  end;

  -- 4) running with less than a full month since the last run is rejected
  begin
    perform post_depreciation(v_asset1, '2025-03-15'::date);
    raise exception 'TEST FAIL: ran depreciation with less than a full month elapsed';
  exception when sqlstate '23514' then null;
  end;

  -- 5) depreciation caps at the depreciable base even if a huge span is requested
  perform post_depreciation(v_asset1, '2030-01-01'::date);
  assert (select accumulated_depreciation from fixed_assets where id = v_asset1) = 12000,
    'accumulated depreciation should cap at the full depreciable base (12000), never exceed it';
  begin
    perform post_depreciation(v_asset1, '2031-01-01'::date);
    raise exception 'TEST FAIL: depreciated a fully-depreciated asset further';
  exception when sqlstate '23514' then null;
  end;

  -- 6) dispose a FRESH asset at a LOSS (proceeds below book value)
  v_asset2 := register_fixed_asset(v_org, 'A2', 'حاسوب', v_asset_acc, v_accum_acc, v_dep_exp_acc,
    '2025-01-01'::date, 3000, 0, 24, v_cash);
  perform post_depreciation(v_asset2, '2025-04-01'::date);  -- 3 months x 125 = 375
  assert (select accumulated_depreciation from fixed_assets where id = v_asset2) = 375, 'sanity: 3 months accumulated';
  -- NBV = 3000-375 = 2625, sell for 2000 -> loss 625
  v_entry := dispose_fixed_asset(v_asset2, '2025-04-15'::date, 2000, v_cash, v_gainloss, 'بيع بخسارة');
  assert (select status from fixed_assets where id = v_asset2) = 'disposed', 'should be disposed';
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'disposal-at-loss entry must balance';
  assert account_balance(v_gainloss) = 625, 'loss account should be debited 625 (2625 NBV - 2000 proceeds)';

  -- 7) dispose a FRESH asset at a GAIN (proceeds above book value)
  v_asset3 := register_fixed_asset(v_org, 'A3', 'أثاث', v_asset_acc, v_accum_acc, v_dep_exp_acc,
    '2025-01-01'::date, 1000, 0, 10, v_cash);
  -- no depreciation posted yet, NBV = 1000, sell for 1500 -> gain 500
  v_entry := dispose_fixed_asset(v_asset3, '2025-01-10'::date, 1500, v_cash, v_gainloss, 'بيع بربح');
  assert account_balance(v_gainloss) = 625 - 500, 'gain should net the loss account down by 500 (625 - 500 = 125)';
  assert (select accumulated_depreciation from fixed_assets where id = v_asset3) = 0, 'no depreciation was ever posted on this one';

  -- 8) dispose exactly at book value (no depreciation posted) -> no gain/loss line needed, no account required
  declare v_asset4 uuid; v_gl_lines_before int; v_gl_lines_after int;
  begin
    v_asset4 := register_fixed_asset(v_org, 'A4', 'طابعة', v_asset_acc, v_accum_acc, v_dep_exp_acc,
      '2025-01-01'::date, 500, 0, 5, v_cash);
    v_entry := dispose_fixed_asset(v_asset4, '2025-01-05'::date, 500, v_cash, null, null);
    assert (select count(*) from journal_lines where entry_id = v_entry) = 2, 'exact-book-value disposal needs only 2 lines (cash in, asset out)';
  end;

  -- 9) immutable fields cannot be changed after registration
  begin
    update fixed_assets set cost = 99999 where id = v_asset1;
    raise exception 'TEST FAIL: changed cost on a registered asset';
  exception when sqlstate '23514' then null;
  end;
  -- but cosmetic fields can
  update fixed_assets set notes = 'ملاحظة محدّثة' where id = v_asset1;
  assert (select notes from fixed_assets where id = v_asset1) = 'ملاحظة محدّثة', 'cosmetic field should be editable';

  -- 10) fixed assets and depreciation runs can never be deleted
  begin
    delete from fixed_assets where id = v_asset1;
    raise exception 'TEST FAIL: deleted a fixed asset';
  exception when sqlstate '23514' then null;
  end;
  begin
    delete from fixed_asset_depreciation_runs where asset_id = v_asset1;
    raise exception 'TEST FAIL: deleted a depreciation run';
  exception when sqlstate '23514' then null;
  end;

  -- 11) cannot depreciate or dispose an already-disposed asset
  begin
    perform post_depreciation(v_asset2, '2025-05-01'::date);
    raise exception 'TEST FAIL: depreciated a disposed asset';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform dispose_fixed_asset(v_asset2, '2025-05-01'::date, 0, null, null, null);
    raise exception 'TEST FAIL: disposed an already-disposed asset';
  exception when sqlstate '23514' then null;
  end;

  -- 12) depreciate_all_assets(): batch-runs every active asset, returns
  -- (asset_id, journal_entry_id, amount) rows, and skips a disposed one
  -- without erroring the whole batch
  declare v_asset5 uuid; v_batch record; v_batch_count int := 0;
  begin
    v_asset5 := register_fixed_asset(v_org, 'A5', 'خزنة', v_asset_acc, v_accum_acc, v_dep_exp_acc,
      '2025-01-01'::date, 2400, 0, 24, v_cash);  -- 100/month
    for v_batch in select * from depreciate_all_assets(v_org, '2025-02-01'::date) loop
      v_batch_count := v_batch_count + 1;
      if v_batch.asset_id = v_asset5 then
        assert v_batch.amount = 100, 'asset5 should show 100 in the batch result';
      end if;
    end loop;
    assert v_batch_count >= 1, 'batch runner should have returned at least asset5''s row';
    assert (select accumulated_depreciation from fixed_assets where id = v_asset5) = 100,
      'batch runner should have actually posted the depreciation, not just reported it';
    -- v_asset2/v_asset3 are disposed by this point — confirm the batch didn't
    -- error out trying to touch them (it filters on status='active' up front,
    -- but assert nothing changed as a second line of defense)
    assert (select accumulated_depreciation from fixed_assets where id = v_asset2) = 375,
      'disposed asset2 should be untouched by the batch runner';
  end;

  raise notice 'FIXED ASSETS OK';
end $$;

rollback;
