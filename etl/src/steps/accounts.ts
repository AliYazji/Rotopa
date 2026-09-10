import { q, type LegacyAccount } from '../legacy.ts';
import { pool } from '../target.ts';
import { env } from '../env.ts';

const NATURE: Record<number, string> = { 1: 'credit', 2: 'debit', 3: 'both' };
const CASHFLOW: Record<number, string> = { 1: 'cash', 2: 'operating', 3: 'investing', 4: 'financing' };

export async function migrateAccounts(orgId: string): Promise<void> {
  const rows = await q<LegacyAccount>(`
    SELECT acc_no, arabic_name, acc_name, father_acc, acc_lavel, account_nature,
           currncey, accountCategoryType, CashFlowClass, StopTransaction,
           ISNULL(delete_flage, 0) AS del
    FROM master_acc
    WHERE ISNULL(delete_flage, 0) = 0`);

  const byCode = new Map(rows.map((r) => [r.acc_no.trim(), r]));
  const childrenOf = new Map<string, number>();
  for (const r of rows) {
    const f = r.father_acc?.trim();
    if (f) childrenOf.set(f, (childrenOf.get(f) ?? 0) + 1);
  }

  // currency legacy_no -> our currency id
  const curRows = await pool.query(`select id, legacy_no from currencies where org_id = $1`, [orgId]);
  const curByLegacy = new Map<number, string>(curRows.rows.map((c: any) => [c.legacy_no, c.id]));

  // category legacy_no -> our id
  const catRows = await pool.query(`select id, legacy_no from account_categories where org_id = $1`, [orgId]);
  const catByLegacy = new Map<number, string>(catRows.rows.map((c: any) => [c.legacy_no, c.id]));

  // insert parents before children: sort by depth in the father chain
  const depth = (code: string, seen = new Set<string>()): number => {
    const r = byCode.get(code);
    const f = r?.father_acc?.trim();
    if (!f || !byCode.has(f) || seen.has(code)) return 0;
    seen.add(code);
    return 1 + depth(f, seen);
  };
  const ordered = [...rows].sort((a, b) => depth(a.acc_no.trim()) - depth(b.acc_no.trim()));

  const idByCode = new Map<string, string>();
  let n = 0, skippedParent = 0;

  for (const r of ordered) {
    const code = r.acc_no.trim();
    const fatherCode = r.father_acc?.trim() || null;
    const parentId = fatherCode ? idByCode.get(fatherCode) ?? null : null;
    if (fatherCode && !parentId) {
      skippedParent++;
      console.warn(`  ! account ${code}: father ${fatherCode} not found, inserting as root`);
    }

    const hasChildren = (childrenOf.get(code) ?? 0) > 0;
    const isPostable = !hasChildren && r.acc_lavel !== 2;

    const legacyCur = r.currncey ?? env.org.baseCurrencyLegacyNo;
    const currencyId =
      legacyCur !== env.org.baseCurrencyLegacyNo ? curByLegacy.get(legacyCur) ?? null : null;

    const categoryId = r.accountCategoryType ? catByLegacy.get(r.accountCategoryType) ?? null : null;

    const res = await pool.query(
      `insert into accounts
         (org_id, code, name_ar, name_en, parent_id, category_id, nature, is_postable,
          allow_transactions, currency_id, cashflow_class, legacy_code)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
       on conflict (org_id, code) do update
         set name_ar = excluded.name_ar, parent_id = excluded.parent_id,
             category_id = excluded.category_id, nature = excluded.nature,
             is_postable = excluded.is_postable, allow_transactions = excluded.allow_transactions,
             currency_id = excluded.currency_id, cashflow_class = excluded.cashflow_class
       returning id`,
      [
        orgId, code,
        r.arabic_name?.trim() || r.acc_name?.trim() || code,
        r.acc_name?.trim() || null,
        parentId ?? null,
        categoryId,
        NATURE[r.account_nature ?? 3] ?? 'both',
        isPostable,
        r.StopTransaction !== 1,
        currencyId,
        r.CashFlowClass ? CASHFLOW[r.CashFlowClass] ?? null : null,
        code,
      ],
    );
    idByCode.set(code, res.rows[0].id);
    n++;
  }
  console.log(`  accounts: ${n}${skippedParent ? `, ${skippedParent} re-rooted` : ''}`);
}
