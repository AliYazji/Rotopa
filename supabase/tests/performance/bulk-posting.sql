-- Bulk-posting smoke check: post 300 journal entries in a loop and report
-- elapsed time. This is NOT a real load/benchmark suite — this project has
-- no production-scale dataset yet to benchmark against honestly, and
-- inventing synthetic "production load" numbers would be worse than not
-- claiming them. What this DOES catch: a gross regression (a missing
-- index, an accidentally-O(n²) trigger, a lock held too long) that would
-- make 300 sequential posts take, say, minutes instead of seconds — the
-- kind of thing that's obvious once you see it and easy to miss otherwise.
\timing on
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('c1000000-0000-0000-0001-000000000001','perf@test');
select set_config('request.jwt.claim.sub','c1000000-0000-0000-0001-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PERFORG','مؤسسة اختبار الأداء','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_a uuid; v_b uuid; v_base uuid;
  i int;
  v_start timestamptz := clock_timestamp();
  v_elapsed_ms numeric;
begin
  select base_currency_id into v_base from organizations where id = v_org;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'A','b',v_parent,true,'debit') returning id into v_a;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'B','c',v_parent,true,'credit') returning id into v_b;

  for i in 1..300 loop
    perform post_journal_entry(create_journal_entry(v_org, current_date, 'قيد اختبار أداء ' || i,
      jsonb_build_array(jsonb_build_object('account_id', v_a, 'debit', 10, 'currency_id', v_base),
                         jsonb_build_object('account_id', v_b, 'credit', 10, 'currency_id', v_base))));
  end loop;

  v_elapsed_ms := extract(epoch from (clock_timestamp() - v_start)) * 1000;
  raise notice 'posted 300 journal entries in % ms (% ms/entry)', round(v_elapsed_ms), round(v_elapsed_ms / 300, 2);

  -- generous ceiling — this is a regression tripwire, not a performance
  -- target. 300 entries taking over 30s on ANY hardware means something is
  -- structurally wrong (an O(n²) trigger, a missing index), not "slow disk".
  if v_elapsed_ms > 30000 then
    raise exception 'bulk posting took %.0f ms for 300 entries — investigate for a regression (missing index, O(n^2) trigger, lock contention)', v_elapsed_ms;
  end if;

  assert (select count(*) from journal_entries where org_id = v_org and status = 'posted') = 300, 'all 300 entries should have posted';
  assert account_balance(v_a) = 3000, 'account A should have accumulated exactly 300 * 10 debit';
end $$;

-- confirm the hot "posted entries for an account, within a date range"
-- query path actually uses the index it's supposed to, not a sequential
-- scan — account_period_balances is exactly the O(1)-rollup table module 05
-- built so trial_balance() never has to scan journal_lines directly.
explain (costs off)
select debit_base, credit_base from account_period_balances where account_id = (select id from accounts where code = 'A' and org_id = current_setting('t.org')::uuid);

rollback;
