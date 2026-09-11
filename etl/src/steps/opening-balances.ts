import { q } from '../legacy.ts';
import { pool, tx, iso } from '../target.ts';

/**
 * One opening journal entry, dated at the start of the organization's current
 * fiscal year, carrying forward the legacy ledger into the new chart.
 *
 * The legacy backup has no usable stored balance (master_acc.initial_balance
 * and .BLANCE are both empty in this dump), so each account's balance is the
 * net of its full acc_trn history — computed the way the legacy application
 * itself computed it (see dbo.Account_Balance_Trns_DB_CR, still callable
 * against the restored database): sum acc_trn.AccAmount (the row's amount in
 * the ACCOUNT's own currency), split by whether DBAmount is zero, not by
 * summing DBAmount/CRAmount directly — those turn out NOT to be reliable
 * amount fields for every row (see etl/README.md for what that changes and
 * why it matters: the naive DBAmount/CRAmount sum happens to net to ~0 across
 * the whole ledger, which looks reassuring but is coincidental — it does not
 * match what the legacy app itself would have reported).
 *
 * Income and expense accounts are NOT carried forward individually — a real
 * cut-over closes them first. We classify by the legacy master_acc.class_acc
 * (4 = trading/income, 5 = expense; confirmed against every account in the
 * source before trusting it — see etl/README.md) and net them into one line
 * against a retained-earnings account, exactly like a year-end closing entry.
 * Only balance-sheet accounts (asset/liability/equity) are carried forward
 * one-for-one.
 *
 * Anything left over — accounts absent from the migrated chart, and the plug
 * needed to force the entry to balance exactly — goes to an explicit
 * "opening balance variance" account instead of being dropped.
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

  const legacyBalances = await q<{ ACC_NO: string; net: number }>(`
    SELECT ACC_NO,
           SUM(CASE WHEN DBAmount = 0 THEN 0 ELSE AccAmount END)
         - SUM(CASE WHEN DBAmount <> 0 THEN 0 ELSE AccAmount END) AS net
    FROM acc_trn
    WHERE ISNULL(delete_flage, 0) = 0
    GROUP BY ACC_NO
    HAVING SUM(CASE WHEN DBAmount = 0 THEN 0 ELSE AccAmount END)
         <> SUM(CASE WHEN DBAmount <> 0 THEN 0 ELSE AccAmount END)`);

  const legacyClass = await q<{ acc_no: string; class_acc: number | null }>(
    `SELECT acc_no, class_acc FROM master_acc`,
  );
  const classByCode = new Map(legacyClass.map((r) => [r.acc_no.trim(), r.class_acc]));
  const isIncomeStatement = (code: string) => [4, 5].includes(classByCode.get(code) ?? -1);

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

  const variance = await ensureAccount(orgId, 'OB-VAR', 'فروقات الأرصدة الافتتاحية', 'Opening balance variance');
  const retained = await ensureAccount(orgId, 'RE', 'الأرباح المرحّلة (افتتاحية)', 'Retained earnings — opening');

  interface Line { account_id: string; currency_id: string; rate: number; fc: number; }
  const lines: Line[] = [];
  let matchedBS = 0, closedPnL = 0, skipped = 0;
  let netIncomeBase = 0; // sum of P&L account net_base (revenue negative, expense positive)

  for (const r of legacyBalances) {
    const net = Number(r.net);
    if (Math.abs(net) < 0.0001) continue;
    const code = r.ACC_NO.trim();
    const acc = accByCode.get(code);

    if (!acc || !acc.postable) {
      skipped++;
      console.warn(`  ! account ${code} (balance ${net.toFixed(3)}) not found/not postable, folded into variance`);
      lines.push({ account_id: variance, currency_id: baseCurrency, rate: 1, fc: net });
      continue;
    }

    const currencyId = acc.currencyId ?? baseCurrency;
    const rate = await rateFor(currencyId);

    if (isIncomeStatement(code)) {
      closedPnL++;
      netIncomeBase += round4(net * rate);
      continue; // closed to retained earnings below, not carried as its own line
    }

    matchedBS++;
    lines.push({ account_id: acc.id, currency_id: currencyId, rate, fc: net });
  }

  // net income = -(sum of P&L nets): revenue nets negative, expense nets positive
  const netIncome = round4(-netIncomeBase);
  if (netIncome !== 0) {
    lines.push({ account_id: retained, currency_id: baseCurrency, rate: 1, fc: -netIncome }); // credit if profit
  }

  const baseAmount = (l: Line) => round4(l.fc * l.rate);
  const totalBase = lines.reduce((s, l) => s + baseAmount(l), 0);
  const plug = round4(-totalBase);
  if (plug !== 0) {
    lines.push({ account_id: variance, currency_id: baseCurrency, rate: 1, fc: plug });
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
    `  opening balances: posted (${matchedBS} balance-sheet accounts, ${closedPnL} P&L accounts closed ` +
      `to retained earnings [net ${netIncome.toFixed(4)}], ${skipped} folded into variance` +
      `${plug !== 0 ? `, plug ${plug.toFixed(4)}` : ''}) as of ${iso(new Date(cutoverDate))}`,
  );
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}

async function ensureAccount(orgId: string, code: string, nameAr: string, nameEn: string): Promise<string> {
  const existing = await pool.query(`select id from accounts where org_id = $1 and code = $2`, [orgId, code]);
  if (existing.rows[0]) return existing.rows[0].id;
  const res = await pool.query(
    `insert into accounts (org_id, code, name_ar, name_en, is_postable, nature, notes)
     values ($1,$2,$3,$4, true, 'both', 'أُنشئ آلياً أثناء الترحيل من miles2023')
     returning id`,
    [orgId, code, nameAr, nameEn],
  );
  return res.rows[0].id;
}
