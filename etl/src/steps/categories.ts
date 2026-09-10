import { q, type LegacyCategory } from '../legacy.ts';
import { pool } from '../target.ts';

// legacy accountCategoryType_tb.CategoryTypGroup -> financial-statement placement
const GROUP: Record<number, { statement: string; section: string; normal: string }> = {
  10:  { statement: 'balance_sheet',    section: 'asset',     normal: 'debit'  },
  20:  { statement: 'balance_sheet',    section: 'asset',     normal: 'debit'  },
  30:  { statement: 'balance_sheet',    section: 'liability', normal: 'credit' },
  40:  { statement: 'balance_sheet',    section: 'liability', normal: 'credit' },
  50:  { statement: 'balance_sheet',    section: 'equity',    normal: 'credit' },
  100: { statement: 'income_statement', section: 'income',    normal: 'credit' },
  110: { statement: 'income_statement', section: 'expense',   normal: 'debit'  },
  120: { statement: 'income_statement', section: 'income',    normal: 'credit' },
  130: { statement: 'income_statement', section: 'expense',   normal: 'debit'  },
};

export async function migrateCategories(orgId: string): Promise<void> {
  const rows = await q<LegacyCategory>(`
    SELECT CategoryTypeNo, CategoryTypeName, CategoryTypeNameEng, CategoryTypGroup, CategoryTypeSort
    FROM accountCategoryType_tb
    WHERE CategoryTypeNo > 0
    ORDER BY CategoryTypeSort, CategoryTypeNo`);

  let n = 0;
  for (const r of rows) {
    const g = GROUP[r.CategoryTypGroup ?? 0];
    if (!g) {
      console.warn(`  ! category ${r.CategoryTypeNo} has unknown group ${r.CategoryTypGroup}, skipped`);
      continue;
    }
    await pool.query(
      `insert into account_categories
         (org_id, code, name_ar, name_en, statement, section, normal_balance, sort_order, legacy_no)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       on conflict (org_id, code) do update
         set name_ar = excluded.name_ar, statement = excluded.statement,
             section = excluded.section, normal_balance = excluded.normal_balance,
             sort_order = excluded.sort_order, legacy_no = excluded.legacy_no`,
      [
        orgId,
        `L${r.CategoryTypeNo}`,
        r.CategoryTypeName ?? `فئة ${r.CategoryTypeNo}`,
        r.CategoryTypeNameEng,
        g.statement, g.section, g.normal,
        r.CategoryTypeSort ?? 0,
        r.CategoryTypeNo,
      ],
    );
    n++;
  }
  console.log(`  account_categories: ${n}`);
}
