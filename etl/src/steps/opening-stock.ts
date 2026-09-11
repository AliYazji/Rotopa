import { q } from '../legacy.ts';
import { pool, tx } from '../target.ts';

/**
 * One opening stock_move (move_type='opening') carrying forward each item's
 * net quantity from the full Item_stock_Details history (177,885 rows), at
 * a moving-average cost derived from its incoming rows only (qty_in
 * weighted by price — an out-row's price is a selling/issue price in this
 * legacy data, not a cost, so it's excluded from the average).
 *
 * Inserted directly (not via create_stock_move()/post_stock_move()): those
 * RPCs are permission-gated on auth.uid(), which is NULL for this script's
 * plain superuser connection — the same reason opening-balances.ts inserts
 * journal_entries/journal_lines directly instead of calling
 * create_journal_entry(). The validation triggers still run either way (they
 * don't check permissions, only data integrity), so this is exactly as safe.
 *
 * Deliberately posts NO general-ledger entry: the accounting opening-balance
 * step already migrated whatever inventory-account balance existed in the
 * legacy books at the GL level (acc_trn), and Item_stock_Details is an
 * entirely separate ledger — posting inventory value again here would
 * double it. This step is quantity (and cost-basis) only.
 */
export async function migrateOpeningStock(orgId: string): Promise<void> {
  const already = await pool.query(
    `select 1 from stock_moves where org_id = $1 and move_type = 'opening' and source_type = 'etl_opening_stock'`,
    [orgId],
  );
  if (already.rows[0]) {
    console.log('  opening stock: already posted, skipped');
    return;
  }

  const rows = await q<{ item_no: string; store_no: number; net: number; avg_cost: number | null }>(`
    SELECT item_no, store_no,
           SUM(qty_in) - SUM(qty_out) AS net,
           SUM(qty_in * price) / NULLIF(SUM(qty_in), 0) AS avg_cost
    FROM Item_stock_Details
    GROUP BY item_no, store_no
    HAVING SUM(qty_in) - SUM(qty_out) <> 0`);

  const itemRows = await pool.query(`select id, legacy_code from items where org_id = $1`, [orgId]);
  const itemByCode = new Map<string, string>(itemRows.rows.map((r: any) => [String(r.legacy_code).trim(), r.id]));
  const whRows = await pool.query(`select id, legacy_no from warehouses where org_id = $1`, [orgId]);
  // warehouses.legacy_no is bigint — node-postgres returns bigint as a
  // string (to avoid precision loss above Number.MAX_SAFE_INTEGER), while
  // the SQL Server driver returns store_no as a plain number; Number() both
  // sides so the Map lookup below doesn't silently miss on every row.
  const whByLegacy = new Map<number, string>(whRows.rows.map((r: any) => [Number(r.legacy_no), r.id]));

  const fy = await pool.query(
    `select start_date::text as d from fiscal_years where org_id = $1 order by start_date limit 1`,
    [orgId],
  );
  const cutoverDate: string = process.env.OPENING_BALANCE_DATE || fy.rows[0]?.d;
  if (!cutoverDate) throw new Error('no fiscal year found — run the accounts step first');

  interface Line { item_id: string; warehouse_id: string; qty: number; cost: number }
  const lines: Line[] = [];
  let negativeSkipped = 0, unmatchedSkipped = 0, noCostDefaulted = 0;

  for (const r of rows) {
    const itemId = itemByCode.get(r.item_no.trim());
    const warehouseId = whByLegacy.get(r.store_no);
    if (!itemId || !warehouseId) { unmatchedSkipped++; continue; }
    if (r.net < 0) { negativeSkipped++; continue; }   // legacy history oversold here — can't post negative stock
    let cost = Number(r.avg_cost);
    if (!cost || cost <= 0) { cost = 0; noCostDefaulted++; }
    lines.push({ item_id: itemId, warehouse_id: warehouseId, qty: round4(Number(r.net)), cost: round4(cost) });
  }

  console.log(
    `  matched ${lines.length}, ${negativeSkipped} negative-net skipped, ${unmatchedSkipped} unmatched item/warehouse`,
  );
  if (lines.length === 0) {
    console.log('  opening stock: nothing to post');
    return;
  }

  await tx(async (c) => {
    const no = (await c.query(`select app.next_seq($1,'stock_move_opening') n`, [orgId])).rows[0].n;
    const move = (await c.query(
      `insert into stock_moves (org_id, move_no, move_date, move_type, description, source_type, status)
       values ($1,$2,$3,'opening','رصيد مخزون افتتاحي منقول من miles2023','etl_opening_stock','draft')
       returning id`,
      [orgId, no, cutoverDate],
    )).rows[0].id;

    let lineNo = 0;
    for (const l of lines) {
      lineNo++;
      await c.query(
        `insert into stock_move_lines (move_id, line_no, item_id, warehouse_id, direction, entered_qty, base_qty, unit_cost)
         values ($1,$2,$3,$4,'in',$5,$5,$6)`,
        [move, lineNo, l.item_id, l.warehouse_id, l.qty, l.cost],
      );
      await c.query(
        `insert into item_warehouse_balances (org_id, item_id, warehouse_id, qty, avg_cost)
         values ($1,$2,$3,$4,$5)
         on conflict (item_id, warehouse_id) do update
           set qty = item_warehouse_balances.qty + excluded.qty,
               avg_cost = round(
                 ((item_warehouse_balances.qty * item_warehouse_balances.avg_cost) + (excluded.qty * excluded.avg_cost))
                 / nullif(item_warehouse_balances.qty + excluded.qty, 0), 4),
               updated_at = now()`,
        [orgId, l.item_id, l.warehouse_id, l.qty, l.cost],
      );
    }
    await c.query(`update stock_moves set status = 'posted', posted_at = now() where id = $1`, [move]);
  });

  console.log(
    `  opening stock: posted ${lines.length} item/warehouse lines` +
      `${noCostDefaulted ? ` (${noCostDefaulted} with no known cost, defaulted to 0 — review these)` : ''}` +
      ` as of ${cutoverDate}`,
  );
  console.log(
    `  ! ${negativeSkipped} item/warehouse pairs had a NEGATIVE net quantity in the legacy history ` +
      `(sold more than was ever received there — a pre-existing data problem, not something this step ` +
      `can fix) and were skipped entirely; ${unmatchedSkipped} referenced an item or store not in the migrated chart.`,
  );
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}
