import { q } from '../legacy.ts';
import { pool } from '../target.ts';
import { env } from '../env.ts';

/** currancy_rate_tb is wide (currancy_rate1..30 + Buy/sales variants per date). Unpivot to rows. */
export async function migrateRates(orgId: string): Promise<void> {
  const curRows = await pool.query(
    `select id, legacy_no from currencies where org_id = $1 and legacy_no is not null and is_base = false`,
    [orgId],
  );
  const curByLegacy = new Map<number, string>(curRows.rows.map((c: any) => [c.legacy_no, c.id]));
  if (curByLegacy.size === 0) {
    console.log('  rates: no non-base currencies, skipped');
    return;
  }

  const cols: string[] = [];
  for (const n of curByLegacy.keys()) {
    cols.push(`currancy_rate${n} AS r${n}`, `currancy_rate_Buy${n} AS b${n}`, `currancy_rate_sales${n} AS s${n}`);
  }
  const rows = await q<any>(
    `SELECT CONVERT(char(10), currancy_date, 23) AS d, ${cols.join(', ')}
     FROM currancy_rate_tb
     WHERE currancy_date IS NOT NULL
     ORDER BY currancy_date`,
  );

  let inserted = 0;
  for (const row of rows) {
    for (const [legacyNo, currencyId] of curByLegacy) {
      const rate = row[`r${legacyNo}`];
      if (rate == null || Number(rate) <= 0) continue;
      const buy = num(row[`b${legacyNo}`]);
      const sell = num(row[`s${legacyNo}`]);
      await pool.query(
        `insert into exchange_rates (org_id, currency_id, rate_date, rate, buy_rate, sell_rate)
         values ($1,$2,$3,$4,$5,$6)
         on conflict (org_id, currency_id, rate_date) do update
           set rate = excluded.rate, buy_rate = excluded.buy_rate, sell_rate = excluded.sell_rate`,
        [orgId, currencyId, row.d, rate, buy, sell],
      );
      inserted++;
    }
  }
  console.log(`  exchange_rates: ${inserted} (base legacy #${env.org.baseCurrencyLegacyNo} excluded)`);
}

function num(v: any): number | null {
  return v == null || Number(v) <= 0 ? null : Number(v);
}
