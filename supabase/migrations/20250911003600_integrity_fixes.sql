-- ============================================================================
-- Two real findings from a full-system integrity audit requested by the
-- user ("إعمل تشيك ... هل هناك أخطاء أو علاقات خاطئة"), both confirmed by
-- direct inspection of the live schema, not guessed:
-- ============================================================================

-- 1) app.vat_rate() — the zero-arg overload from the original VAT feature
-- (20250911002000_vat.sql) was never dropped when 20250911003500 replaced
-- it with app.vat_rate(p_org uuid). Postgres treats a different argument
-- list as a DIFFERENT function, so `create or replace` never removed the
-- old one — it silently kept living in the schema, still returning a
-- hardcoded 0.16 forever, disconnected from every org's real tax settings.
-- Confirmed zero live callers (every remaining app.vat_rate() call site is
-- inside an already-superseded, dead function body from an earlier
-- create-or-replace round) before dropping it.
drop function if exists app.vat_rate();

-- 2) bom_lines was the one reference table in the whole schema with no
-- cross-organization check on its item references — every other line/
-- detail table (sales_invoice_lines, manufacturing_order_lines, voucher
-- lines, ...) validates this via a BEFORE trigger; bom_lines skipped it.
-- Not an active security hole (app.tg_stock_move_line_validate() already
-- blocks any actual cross-org stock consumption at posting time), but a
-- real inconsistency: a recipe linking items from two different orgs could
-- be saved with no error, only failing later and confusingly at posting.
create or replace function app.tg_bom_lines_validate()
returns trigger language plpgsql as $$
declare v_finished_org uuid; v_component_org uuid;
begin
  select org_id into v_finished_org from items where id = new.finished_item_id;
  if v_finished_org is distinct from new.org_id then
    raise exception 'finished item belongs to a different organization' using errcode = '23503';
  end if;
  select org_id into v_component_org from items where id = new.component_item_id;
  if v_component_org is distinct from new.org_id then
    raise exception 'component item belongs to a different organization' using errcode = '23503';
  end if;
  return new;
end;
$$;

create trigger bom_lines_validate
  before insert or update on bom_lines
  for each row execute function app.tg_bom_lines_validate();
