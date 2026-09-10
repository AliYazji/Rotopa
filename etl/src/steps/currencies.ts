import { q, type LegacyCurrency } from '../legacy.ts';
import { pool } from '../target.ts';
import { env } from '../env.ts';

export async function migrateCurrencies(orgId: string): Promise<void> {
  const rows = await q<LegacyCurrency>(`
    SELECT FieldNo, ADescName, EDescName, Simbol, curr_str1, curr_str2
    FROM Lockup_tb
    WHERE LTRIM(RTRIM(FieldName)) = 'Currancy'
      AND FieldNo > 0 AND ISNULL(DeleteFlage, 0) = 0
    ORDER BY FieldNo`);

  let base = 0, other = 0;
  for (const c of rows) {
    const code = (c.EDescName || c.Simbol || `C${c.FieldNo}`).trim().slice(0, 12);
    const isBase = c.FieldNo === env.org.baseCurrencyLegacyNo;
    if (isBase) {
      await pool.query(
        `update currencies
            set code = $2, name_ar = $3, name_en = $4, symbol = $5,
                minor_unit_ar = $6, legacy_no = $7
          where org_id = $1 and is_base = true`,
        [orgId, code, c.ADescName ?? code, c.EDescName, c.Simbol, c.curr_str2, c.FieldNo],
      );
      base++;
    } else {
      await pool.query(
        `insert into currencies (org_id, code, name_ar, name_en, symbol, minor_unit_ar, legacy_no, is_base, decimal_places)
         values ($1,$2,$3,$4,$5,$6,$7,false,2)
         on conflict (org_id, code) do update
           set name_ar = excluded.name_ar, legacy_no = excluded.legacy_no`,
        [orgId, code, c.ADescName ?? code, c.EDescName, c.Simbol, c.curr_str2, c.FieldNo],
      );
      other++;
    }
  }
  console.log(`  currencies: base=${base}, other=${other}`);
}
