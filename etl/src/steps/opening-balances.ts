import { q } from '../legacy.ts';
import { pool, tx, iso } from '../target.ts';

/**
 * One opening journal entry, dated at the start of the organization's current
 * fiscal year, carrying each account's net balance from the legacy ledger
 * (acc_trn, summed to date — the legacy backup has no reliable stored
 * balance: master_acc.BLANCE / initial_balance are both empty in this dump).
 *
 * acc_trn.DBAmount/CRAmount are already in the account's own currency, so a
 * foreign-currency account posts in its own currency at the exchange rate on
 * the cutover date (fx_rate) — same as any other journal line.
 *
 * Any residual mismatch (the legacy ledger itself is off by a few cents — see
 * docs/data-model.md) is posted to an explicit "opening balance variance"
 * account instead of silently dropped, so it stays auditable.
 */
export async function migrateOpeningBalances(orgId: string): Promise<void> {
  const already = await pool.query(
    `select 1 from journal_entries where org_id = $1 and source_type = 'opening_balance'`,
    [orgId],
  );
  if (already.rows[0]) {
    console.log('  opening balances: already posted, skipped');
    return;
  }

  const legacyBalances = await q<{ ACC_NO: string; db: number; cr: number }>(`
    SELECT ACC_NO, SUM(DBAmount) AS db, SUM(CRAmount) AS cr
    FROM acc_trn
    WHERE ISNULL(delete_flage, 0) = 0
    GROUP BY ACC_NO
    HAVING SUM(DBAmount) <> SUM(CRAmount)`);

  const accRows = await pool.query(
    `select id, legacy_code, is_postable, currency_id from accounts where org_id = $1`,
    [orgId],
  );
  const accByCode = new Map<string, { id: string; postable: boolean; currencyId: string | null }>(
    accRows.rows.map((a: any) => [String(a.legacy_code).trim(), { id: a.id, postable: a.is_postable, currencyId: a.currency_id }]),
  );

  const fy = await pool.query(
    `select start_date::text as d from fiscal_years where org_id = $1 order by start_date limit 1`,
    [orgId],
  );
  const cutoverDate: string = process.env.OPENING_BALANCE_DATE || fy.rows[0]?.d;
  if (!cutoverDate) throw new Error('no fiscal year found — run the accounts step first');

  const baseCurrency: string = (await pool.query(`select base_currency_id id from organizations where id = $1`, [orgId])).rows[0].id;
  const rateCache = new Map<string, number>([[baseCurrency, 1]]);
  async function rateFor(currencyId: string): Promise<number> {
    if (!rateCache.has(currencyId)) {
      const r = await pool.query(`select fx_rate($1,$2::date) r`, [currencyId, cutoverDate]);
      rateCache.set(currencyId, Number(r.rows[0].r));
    }
    return rateCache.get(currencyId)!;
  }

  // receives both unmatched legacy accounts and the plug that forces this entry to balance
  const suspense = await ensureVarianceAccount(orgId);

  interface Line { account_id: string; currency_id: string; rate: number; fc: number; }
  const lines: Line[] = [];
  let matched = 0, skipped = 0;

  for (const r of legacyBalances) {
    const net = Number(r.db) - Number(r.cr);
    if (Math.abs(net) < 0.0001) continue;
    const acc = accByCode.get(r.ACC_NO.trim());
    if (!acc || !acc.postable) {
      skipped++;
      console.warn(`  ! account ${r.ACC_NO} (balance ${net.toFixed(3)}) not found/not postable, folded into variance`);
      lines.push({ account_id: suspense, currency_id: baseCurrency, rate: 1, fc: net });
      continue;
    }
    matched++;
    const currencyId = acc.currencyId ?? baseCurrency;
    lines.push({ account_id: acc.id, currency_id: currencyId, rate: await rateFor(currencyId), fc: net });
  }

  const baseAmount = (l: Line) => round4(l.fc * l.rate);
  const totalBase = lines.reduce((s, l) => s + baseAmount(l), 0);
  const plug = round4(-totalBase);
  if (plug !== 0) {
    lines.push({ account_id: suspense, currency_id: baseCurrency, rate: 1, fc: plug });
  }

  if (lines.length < 2) {
    console.log('  opening balances: nothing to post');
    return;
  }

  await tx(async (c) => {
    const no = (await c.query(`select app.next_seq($1,'journal') n`, [orgId])).rows[0].n;
    const period = (await c.query(`select app.open_period_for($1,$2::date) p`, [orgId, cutoverDate])).rows[0].p;
    const entry = (await c.query(
      `insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description, source_type, is_opening, status)
       values ($1,$2,$3,$4,'رصيد افتتاحي منقول من miles2023','opening_balance', true, 'draft') returning id`,
      [orgId, no, cutoverDate, period],
    )).rows[0].id;

    let lineNo = 0;
    for (const l of lines) {
      lineNo++;
      const base = baseAmount(l);
      const debitFc = l.fc > 0 ? l.fc : 0;
      const creditFc = l.fc < 0 ? -l.fc : 0;
      const debit = base > 0 ? base : 0;
      const credit = base < 0 ? -base : 0;
      await c.query(
        `insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, fc_debit, fc_credit)
         values ($1,$2,$3,'رصيد افتتاحي',$4,$5,$6,$7,$8,$9)`,
        [entry, lineNo, l.account_id, debit, credit, l.currency_id, l.rate, debitFc, creditFc],
      );
    }
    await c.query(`update journal_entries set status='posted', posted_at=now() where id=$1`, [entry]);
  });

  console.log(
    `  opening balances: posted (${matched} accounts, ${skipped} folded into variance` +
      `${plug !== 0 ? `, plug ${plug.toFixed(4)}` : ''}) as of ${iso(new Date(cutoverDate))}`,
  );
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}

async function ensureVarianceAccount(orgId: string): Promise<string> {
  const existing = await pool.query(`select id from accounts where org_id = $1 and code = 'OB-VAR'`, [orgId]);
  if (existing.rows[0]) return existing.rows[0].id;
  const res = await pool.query(
    `insert into accounts (org_id, code, name_ar, name_en, is_postable, nature, notes)
     values ($1,'OB-VAR','فروقات الأرصدة الافتتاحية','Opening balance variance', true, 'both',
             'تُنشأ آلياً أثناء الترحيل من miles2023 لضمان توازن قيد الافتتاح')
     returning id`,
    [orgId],
  );
  return res.rows[0].id;
}
