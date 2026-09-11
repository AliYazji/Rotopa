import { q } from '../legacy.ts';
import { pool } from '../target.ts';

/**
 * Migrates the item/category/warehouse/unit *master data* from ITEM_TB,
 * CategoryItem_tb, center_tb and item_unit.
 *
 * Deliberately NOT migrated here: stock quantities and history
 * (Item_stock_tb/Item_stock_Details, 178k rows). ITEM_TB.QtyInStock is
 * unreliable in this backup (only 3 of 3546 items have it populated — the
 * legacy app evidently computed real stock from the movement history, the
 * same pattern seen with master_acc.BLANCE being empty for accounts). A
 * proper opening-stock migration needs the same care the accounting opening
 * balance got — summing the real ledger, picking a cutover date, reconciling
 * a variance — and belongs in its own step once inventory is in real use.
 */
export async function migrateInventory(orgId: string): Promise<void> {
  const invAcc = await ensureDefaultAccount(orgId, 'INV-DEFAULT', 'المخزون (افتراضي)', 'debit');
  const cogsAcc = await ensureDefaultAccount(orgId, 'COGS-DEFAULT', 'تكلفة البضاعة المباعة (افتراضي)', 'debit');

  // ---- categories --------------------------------------------------------
  const cats = await q<{ Category_no: number; Category_Name: string | null; E_Category_Name: string | null }>(`
    SELECT Category_no, Category_Name, E_Category_Name FROM CategoryItem_tb
    WHERE Category_no > 0 AND Category_Name IS NOT NULL AND LTRIM(RTRIM(Category_Name)) <> ''`);
  const catByLegacy = new Map<number, string>();
  for (const c of cats) {
    const res = await pool.query(
      `insert into item_categories (org_id, code, name_ar, name_en, legacy_no)
       values ($1,$2,$3,$4,$5)
       on conflict (org_id, code) do update set name_ar = excluded.name_ar
       returning id`,
      [orgId, `C${c.Category_no}`, c.Category_Name!.trim(), c.E_Category_Name?.trim() || null, c.Category_no],
    );
    catByLegacy.set(c.Category_no, res.rows[0].id);
  }
  console.log(`  item_categories: ${cats.length}`);

  // ---- warehouses (center_tb) --------------------------------------------
  const centers = await q<{ center_no: number; center_name: string | null }>(
    `SELECT center_no, center_name FROM center_tb`,
  );
  const whByLegacy = new Map<number, string>();
  for (const c of centers) {
    const res = await pool.query(
      `insert into warehouses (org_id, code, name_ar, legacy_no)
       values ($1,$2,$3,$4)
       on conflict (org_id, code) do update set name_ar = excluded.name_ar
       returning id`,
      [orgId, `W${c.center_no}`, c.center_name?.trim() || `مستودع ${c.center_no}`, c.center_no],
    );
    whByLegacy.set(c.center_no, res.rows[0].id);
  }
  if (whByLegacy.size === 0) {
    const res = await pool.query(
      `insert into warehouses (org_id, code, name_ar) values ($1,'MAIN','المستودع الرئيسي')
       on conflict (org_id, code) do update set name_ar = excluded.name_ar returning id`,
      [orgId],
    );
    whByLegacy.set(0, res.rows[0].id);
  }
  console.log(`  warehouses: ${whByLegacy.size}`);

  // ---- items --------------------------------------------------------------
  const items = await q<{
    ITEM_NO: string; ITEM_DESC: string | null; arbic_desc: string | null;
    barcode_no: string | null; category: number | null; unit: string | null;
    PRICE1: number | null; item_status: number | null;
  }>(`
    SELECT ITEM_NO, ITEM_DESC, arbic_desc, barcode_no, category, unit, PRICE1, item_status
    FROM ITEM_TB WHERE ISNULL(delete_flage, 0) = 0`);

  const idByCode = new Map<string, string>();
  let n = 0, dupBarcodes = 0;
  const seenBarcodes = new Set<string>();
  for (const it of items) {
    const code = it.ITEM_NO.trim();
    const name = it.arbic_desc?.trim() || it.ITEM_DESC?.trim() || code;
    let barcode = it.barcode_no?.trim() || null;
    if (barcode) {
      if (seenBarcodes.has(barcode)) { dupBarcodes++; barcode = null; }
      else seenBarcodes.add(barcode);
    }
    const categoryId = it.category ? catByLegacy.get(it.category) ?? null : null;
    const unitName = it.unit?.trim() || 'قطعة';

    const res = await pool.query(
      `insert into items (org_id, code, barcode, name_ar, category_id, base_unit_name,
                           sales_price, inventory_account_id, cogs_account_id, is_active, legacy_code)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       on conflict (org_id, code) do update
         set name_ar = excluded.name_ar, category_id = excluded.category_id,
             base_unit_name = excluded.base_unit_name, sales_price = excluded.sales_price
       returning id`,
      [orgId, code, barcode, name, categoryId, unitName,
       Math.max(0, Number(it.PRICE1) || 0), invAcc, cogsAcc, (it.item_status ?? 0) !== 9, code],
    );
    idByCode.set(code, res.rows[0].id);
    n++;
  }
  console.log(`  items: ${n}${dupBarcodes ? `, ${dupBarcodes} duplicate barcodes dropped` : ''}`);

  // ---- item_units -----------------------------------------------------
  const units = await q<{ item_no: string; unit_name: string | null; unit_qty: number | null; barcode_no: string | null }>(
    `SELECT item_no, unit_name, unit_qty, barcode_no FROM item_unit WHERE unit_qty > 0`,
  );
  let un = 0, unSkipped = 0;
  for (const u of units) {
    const itemId = idByCode.get(u.item_no.trim());
    const name = u.unit_name?.trim();
    if (!itemId || !name) { unSkipped++; continue; }
    await pool.query(
      `insert into item_units (item_id, unit_name, conversion_factor, barcode)
       values ($1,$2,$3,$4)
       on conflict (item_id, unit_name) do update set conversion_factor = excluded.conversion_factor`,
      [itemId, name, u.unit_qty, u.barcode_no?.trim() || null],
    );
    un++;
  }
  console.log(`  item_units: ${un}${unSkipped ? `, ${unSkipped} skipped (unknown item)` : ''}`);
}

async function ensureDefaultAccount(orgId: string, code: string, nameAr: string, nature: string): Promise<string> {
  const existing = await pool.query(`select id from accounts where org_id = $1 and code = $2`, [orgId, code]);
  if (existing.rows[0]) return existing.rows[0].id;
  const res = await pool.query(
    `insert into accounts (org_id, code, name_ar, is_postable, nature, notes)
     values ($1,$2,$3, true, $4, 'أُنشئ آلياً — راجعه واستبدله بحساب مناسب من دليلك عند الحاجة')
     returning id`,
    [orgId, code, nameAr, nature],
  );
  return res.rows[0].id;
}
