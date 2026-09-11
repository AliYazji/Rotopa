-- Income statement + balance sheet: per-account rows tagged by category,
-- balance sheet balances via the unclosed-earnings plug (no periodic
-- closing step exists yet), accounts with no category are excluded.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('c3000000-0000-0000-0003-000000000001','fs@test');
select set_config('request.jwt.claim.sub','c3000000-0000-0000-0003-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('FSORG','مؤسسة اختبار القوائم المالية','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cat_asset uuid; v_cat_liability uuid; v_cat_equity uuid; v_cat_income uuid; v_cat_expense uuid;
  v_parent uuid; v_cash uuid; v_ar uuid; v_ap uuid; v_capital uuid; v_sales uuid; v_rent uuid; v_uncategorized uuid;
  v_e1 uuid;
begin
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance, sort_order)
  values
    (v_org, 'CAT-A', 'الأصول', 'balance_sheet', 'asset', 'debit', 1),
    (v_org, 'CAT-L', 'الالتزامات', 'balance_sheet', 'liability', 'credit', 2),
    (v_org, 'CAT-E', 'حقوق الملكية', 'balance_sheet', 'equity', 'credit', 3),
    (v_org, 'CAT-I', 'الإيرادات', 'income_statement', 'income', 'credit', 4),
    (v_org, 'CAT-X', 'المصروفات', 'income_statement', 'expense', 'debit', 5);
  select id into v_cat_asset from account_categories where org_id = v_org and code = 'CAT-A';
  select id into v_cat_liability from account_categories where org_id = v_org and code = 'CAT-L';
  select id into v_cat_equity from account_categories where org_id = v_org and code = 'CAT-E';
  select id into v_cat_income from account_categories where org_id = v_org and code = 'CAT-I';
  select id into v_cat_expense from account_categories where org_id = v_org and code = 'CAT-X';

  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'CASH','الصندوق',v_parent,true,'debit',v_cat_asset) returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit',v_cat_asset) returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'AP','ذمم موردين',v_parent,true,'credit',v_cat_liability) returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'CAP','رأس المال',v_parent,true,'credit',v_cat_equity) returning id into v_capital;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'SALES','المبيعات',v_parent,true,'credit',v_cat_income) returning id into v_sales;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature, category_id) values (v_org,'RENT','إيجار',v_parent,true,'debit',v_cat_expense) returning id into v_rent;
  -- no category_id at all — must be invisible to both statements
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'MISC','بلا تصنيف',v_parent,true,'debit') returning id into v_uncategorized;

  -- opening: Dr cash 1000 / Cr capital 1000
  v_e1 := create_journal_entry(v_org, current_date, 'رأس مال افتتاحي',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 1000, 'credit', 0, 'currency_id', (select base_currency_id from organizations where id = v_org), 'rate', 1),
      jsonb_build_object('account_id', v_capital, 'debit', 0, 'credit', 1000, 'currency_id', (select base_currency_id from organizations where id = v_org), 'rate', 1)
    ), p_is_opening := true);
  perform post_journal_entry(v_e1);

  -- revenue: Dr AR 500 / Cr sales 500
  v_e1 := create_journal_entry(v_org, current_date, 'فاتورة خدمة',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 500, 'credit', 0, 'currency_id', (select base_currency_id from organizations where id = v_org), 'rate', 1),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 500, 'currency_id', (select base_currency_id from organizations where id = v_org), 'rate', 1)
    ));
  perform post_journal_entry(v_e1);

  -- expense: Dr rent 200 / Cr cash 200
  v_e1 := create_journal_entry(v_org, current_date, 'دفع إيجار',
    jsonb_build_array(
      jsonb_build_object('account_id', v_rent, 'debit', 200, 'credit', 0, 'currency_id', (select base_currency_id from organizations where id = v_org), 'rate', 1),
      jsonb_build_object('account_id', v_cash, 'debit', 0, 'credit', 200, 'currency_id', (select base_currency_id from organizations where id = v_org), 'rate', 1)
    ));
  perform post_journal_entry(v_e1);

  -- income statement: sales 500, rent 200
  assert (select amount from income_statement(v_org, current_date, current_date) where account_id = v_sales) = 500,
    'sales should show 500 on the income statement';
  assert (select amount from income_statement(v_org, current_date, current_date) where account_id = v_rent) = 200,
    'rent should show 200 on the income statement';
  assert not exists (select 1 from income_statement(v_org, current_date, current_date) where account_id = v_uncategorized),
    'an account with no category must not appear on the income statement at all';

  -- balance sheet: cash 800 (1000-200), AR 500, capital 1000, unclosed earnings 300 (500-200)
  assert (select amount from balance_sheet(v_org, current_date) where account_id = v_cash) = 800,
    'cash should show 800 (1000 opening - 200 rent paid)';
  assert (select amount from balance_sheet(v_org, current_date) where account_id = v_ar) = 500, 'AR should show 500';
  assert (select amount from balance_sheet(v_org, current_date) where account_id = v_capital) = 1000, 'capital should show 1000';
  assert (select amount from balance_sheet(v_org, current_date) where category_code = 'UNCLOSED') = 300,
    'unclosed earnings should show 300 (500 income - 200 expense) since there is no periodic closing step';
  assert not exists (select 1 from balance_sheet(v_org, current_date) where account_id = v_uncategorized),
    'an account with no category must not appear on the balance sheet at all';

  -- the statement must actually balance: assets = liabilities + equity (including the unclosed plug)
  assert (select coalesce(sum(amount), 0) from balance_sheet(v_org, current_date) where section = 'asset')
       = (select coalesce(sum(amount), 0) from balance_sheet(v_org, current_date) where section in ('liability', 'equity')),
    'assets must equal liabilities + equity, unclosed-earnings plug included';

  raise notice 'FINANCIAL STATEMENTS OK';
end $$;

rollback;
