import { q, type LegacyDealer } from '../legacy.ts';
import { pool } from '../target.ts';
import { env } from '../env.ts';

/**
 * Dealers_tb is keyed (Dealer_no, Dealer_type) — the same party can appear as
 * customer AND supplier. We merge to one dealer per Dealer_no with role flags.
 */
export async function migrateDealers(orgId: string): Promise<void> {
  const rows = await q<LegacyDealer>(`
    SELECT Dealer_no, Dealer_type, Dealer_name, arabic_name, acc_no, currncey,
           address, city, tel_no, email, reg_no, max_credit_balance,
           sales_discount, purchase_discount
    FROM Dealers_tb`);

  const acc = await pool.query(`select id, legacy_code from accounts where org_id = $1`, [orgId]);
  const accByCode = new Map<string, string>(acc.rows.map((a: any) => [String(a.legacy_code).trim(), a.id]));

  const cur = await pool.query(`select id, legacy_no from currencies where org_id = $1`, [orgId]);
  const curByLegacy = new Map<number, string>(cur.rows.map((c: any) => [c.legacy_no, c.id]));

  const merged = new Map<number, {
    name: string; roles: Set<number>; accCode: string | null; currncey: number | null;
    address: string | null; city: string | null; tel: string | null; email: string | null;
    reg: string | null; credit: number | null; sDisc: number | null; pDisc: number | null;
  }>();

  for (const r of rows) {
    const m = merged.get(r.Dealer_no) ?? {
      name: '', roles: new Set<number>(), accCode: null, currncey: null,
      address: null, city: null, tel: null, email: null, reg: null,
      credit: null, sDisc: null, pDisc: null,
    };
    m.roles.add(r.Dealer_type);
    m.name ||= (r.arabic_name || r.Dealer_name || `#${r.Dealer_no}`).trim();
    m.accCode ??= r.acc_no?.trim() || null;
    m.currncey ??= r.currncey ?? null;
    m.address ??= r.address?.trim() || null;
    m.city ??= r.city?.trim() || null;
    m.tel ??= r.tel_no?.trim() || null;
    m.email ??= r.email?.trim() || null;
    m.reg ??= r.reg_no?.trim() || null;
    m.credit ??= r.max_credit_balance ?? null;
    if (r.Dealer_type === 1) m.sDisc ??= r.sales_discount ?? null;
    if (r.Dealer_type === 2) m.pDisc ??= r.purchase_discount ?? null;
    merged.set(r.Dealer_no, m);
  }

  let n = 0, noAccount = 0;
  for (const [dealerNo, m] of merged) {
    const accountId = m.accCode ? accByCode.get(m.accCode) ?? null : null;
    if (!accountId) {
      noAccount++;
      console.warn(`  ! dealer ${dealerNo} (${m.name}): account ${m.accCode} not in chart, skipped`);
      continue;
    }
    const legacyCur = m.currncey ?? env.org.baseCurrencyLegacyNo;
    const currencyId = legacyCur !== env.org.baseCurrencyLegacyNo ? curByLegacy.get(legacyCur) ?? null : null;

    await pool.query(
      `insert into dealers
         (org_id, code, name_ar, is_customer, is_supplier, is_employee, account_id, currency_id,
          credit_limit, sales_discount_pct, purchase_discount_pct,
          tax_no, commercial_reg_no, phone, email, address, city, legacy_no)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)
       on conflict (org_id, code) do update
         set name_ar = excluded.name_ar, is_customer = excluded.is_customer,
             is_supplier = excluded.is_supplier, is_employee = excluded.is_employee,
             account_id = excluded.account_id`,
      [
        orgId, `D${dealerNo}`, m.name,
        m.roles.has(1), m.roles.has(2), m.roles.has(3),
        accountId, currencyId,
        Math.max(0, m.credit ?? 0),
        clampPct(m.sDisc) ?? 0,
        clampPct(m.pDisc) ?? 0,
        null, m.reg, m.tel, m.email && m.email.includes('@') ? m.email : null,
        m.address, m.city, dealerNo,
      ],
    );
    n++;
  }
  console.log(`  dealers: ${n}${noAccount ? `, ${noAccount} skipped (no account)` : ''}`);
}

function clampPct(v: number | null): number | null {
  if (v == null) return null;
  const x = Number(v);
  if (!isFinite(x) || x < 0) return 0;
  return x > 100 ? 100 : x;
}
