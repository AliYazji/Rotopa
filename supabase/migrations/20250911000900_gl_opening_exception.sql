-- ============================================================================
-- Rotopa · fix — opening-balance entries may post to a stopped account
--
-- allow_transactions ("stop transactions") blocks *new business* activity on
-- an account, but a carry-forward of its existing balance during migration or
-- year-end is not new activity — it is still active/postable that matters.
-- Re-create the validator with a single added exception for is_opening.
-- ============================================================================

create or replace function app.tg_journal_line_validate()
returns trigger language plpgsql as $$
declare
  e   journal_entries%rowtype;
  a   accounts%rowtype;
  cur currencies%rowtype;
begin
  select * into e from journal_entries where id = new.entry_id;
  if not found then
    raise exception 'journal line references a missing entry' using errcode = '23503';
  end if;

  if e.status <> 'draft' then
    raise exception 'entry % is %; its lines are frozen', e.entry_no, e.status using errcode = '23514';
  end if;

  new.org_id := e.org_id;

  select * into a from accounts where id = new.account_id;
  if a.org_id <> e.org_id then
    raise exception 'account belongs to a different organization' using errcode = '23503';
  end if;
  if not a.is_postable then
    raise exception 'account % is not postable', a.code using errcode = '23514';
  end if;
  if not a.is_active then
    raise exception 'account % is inactive', a.code using errcode = '23514';
  end if;
  if not a.allow_transactions and not e.is_opening then
    raise exception 'account % does not currently accept transactions', a.code using errcode = '23514';
  end if;

  select * into cur from currencies where id = new.currency_id;
  if cur.org_id <> e.org_id then
    raise exception 'currency belongs to a different organization' using errcode = '23503';
  end if;
  if a.currency_id is not null and a.currency_id <> new.currency_id then
    raise exception 'account % is restricted to a single currency', a.code using errcode = '23514';
  end if;

  if cur.is_base then
    if new.rate <> 1 then
      raise exception 'base-currency line must have rate = 1' using errcode = '23514';
    end if;
    new.fc_debit  := new.debit;
    new.fc_credit := new.credit;
  else
    if round(new.fc_debit  * new.rate, 4) <> new.debit then
      raise exception 'debit % <> fc_debit % * rate %', new.debit, new.fc_debit, new.rate using errcode = '23514';
    end if;
    if round(new.fc_credit * new.rate, 4) <> new.credit then
      raise exception 'credit % <> fc_credit % * rate %', new.credit, new.fc_credit, new.rate using errcode = '23514';
    end if;
  end if;

  if a.require_dealer      and new.dealer_id      is null then raise exception 'account % requires a dealer',       a.code using errcode='23514'; end if;
  if a.require_cost_center and new.cost_center_id  is null then raise exception 'account % requires a cost centre',  a.code using errcode='23514'; end if;
  if a.require_department   and new.department_id  is null then raise exception 'account % requires a department',   a.code using errcode='23514'; end if;
  if a.require_project      and new.project_id     is null then raise exception 'account % requires a project',      a.code using errcode='23514'; end if;

  if new.dealer_id      is not null and (select org_id from dealers      where id = new.dealer_id)      <> e.org_id then raise exception 'dealer belongs to another org'      using errcode='23503'; end if;
  if new.cost_center_id is not null and (select org_id from cost_centers where id = new.cost_center_id) <> e.org_id then raise exception 'cost centre belongs to another org' using errcode='23503'; end if;
  if new.department_id  is not null and (select org_id from departments  where id = new.department_id)  <> e.org_id then raise exception 'department belongs to another org'  using errcode='23503'; end if;
  if new.fund_id        is not null and (select org_id from funds        where id = new.fund_id)        <> e.org_id then raise exception 'fund belongs to another org'        using errcode='23503'; end if;
  if new.project_id     is not null and (select org_id from projects     where id = new.project_id)     <> e.org_id then raise exception 'project belongs to another org'     using errcode='23503'; end if;

  return new;
end;
$$;
