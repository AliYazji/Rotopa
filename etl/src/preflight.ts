// ============================================================================
// Rotopa · Historical-data preflight report — READ-ONLY.
//
// Run BEFORE applying migrations 20250911004700..20250911005500 to a real,
// pre-existing production database (or a local restore of one). Never
// writes anything: the whole run happens inside one `begin transaction read
// only` — Postgres itself will reject any accidental write statement, not
// just this script's own discipline.
//
// Simulates exactly what those migrations' own backfills will compute
// (same matching logic, reproduced here as plain SELECTs) so ambiguous or
// unresolvable historical rows are surfaced and reviewed BEFORE the real
// migration ever touches production data — never silently defaulted.
//
// Usage:
//   PREFLIGHT_DATABASE_URL=postgres://... npx tsx src/preflight.ts
//   (falls back to TARGET_DATABASE_URL if PREFLIGHT_DATABASE_URL is unset)
// Writes a JSON report to preflight-report.json (or --out=<path>) and
// prints a human-readable summary to stdout.
// ============================================================================
import 'dotenv/config';
import pg from 'pg';
import { writeFileSync } from 'node:fs';

pg.types.setTypeParser(1700, (v) => (v === null ? null : Number(v)));

const connectionString = process.env.PREFLIGHT_DATABASE_URL || process.env.TARGET_DATABASE_URL;
if (!connectionString) {
  console.error('missing env PREFLIGHT_DATABASE_URL (or TARGET_DATABASE_URL) — refusing to guess a connection target');
  process.exit(1);
}
const outPath = process.argv.find((a) => a.startsWith('--out='))?.slice('--out='.length) || 'preflight-report.json';

const pool = new pg.Pool({ connectionString, max: 2 });

async function main() {
  const client = await pool.connect();
  try {
    // hard guarantee: this entire run cannot write anything, even by mistake
    await client.query('begin transaction isolation level repeatable read read only');

    const orgs = (await client.query<{ id: string; code: string; name_ar: string }>(
      `select id, code, name_ar from organizations order by code`,
    )).rows;

    const report: any = { generated_at: new Date().toISOString(), database: redact(connectionString!), orgs: [] };

    for (const org of orgs) {
      console.log(`\n${'='.repeat(78)}\nOrg ${org.code} — ${org.name_ar} (${org.id})\n${'='.repeat(78)}`);
      const orgReport: any = { org_id: org.id, code: org.code, name_ar: org.name_ar };

      orgReport.tax = await taxSection(client, org.id);
      orgReport.return_links = await returnLinksSection(client, org.id);
      orgReport.inventory = await inventorySection(client, org.id);

      report.orgs.push(orgReport);
    }

    await client.query('rollback'); // read-only anyway, but explicit: nothing survives this run
    writeFileSync(outPath, JSON.stringify(report, null, 2), 'utf8');
    console.log(`\nFull report written to ${outPath}`);

    const anyBlocking = report.orgs.some((o: any) =>
      o.tax.unresolved_count > 0 || o.return_links.ambiguous_count > 0 || o.inventory.negative_qty_count > 0 || o.inventory.negative_value_count > 0,
    );
    if (anyBlocking) {
      console.log('\n*** BLOCKING FINDINGS PRESENT — do not proceed with migrating this data until every item above is reviewed. ***');
      process.exitCode = 2;
    } else {
      console.log('\nNo blocking findings. Historical data appears fully reconstructible under the documented policy.');
    }
  } finally {
    client.release();
    await pool.end();
  }
}

function redact(url: string): string {
  try {
    const u = new URL(url);
    if (u.password) u.password = '***';
    return u.toString();
  } catch {
    return '<unparsable>';
  }
}

// ----------------------------------------------------------------------------
// TAX — simulate 20250911004800_tax_snapshot.sql's own backfill matching
// (line-total sum vs. the specific VAT journal_lines description), PLUS an
// independent, description-agnostic-of-VAT-but-not-of-the-control-line
// cross-check: does the document's own CONTROL line (the single line
// carrying (v_total+v_vat)*rate — AR/AP/cash, never the COGS/inventory
// mirror pair, which would otherwise pollute a naive whole-side sum) equal
// v_total + the matched VAT? The control line's own description is a
// separate, independently stable literal (never subject to a custom
// invoice/return description override, unlike the journal ENTRY's own
// description) — grepped across every historical revision, same discipline
// as the VAT-line matching itself. A row where the VAT-line match fails
// AND the control line does NOT reconcile to a clean zero-tax total is
// UNRESOLVED — never silently defaulted to 0%.
// ----------------------------------------------------------------------------
async function taxSection(client: pg.PoolClient, orgId: string) {
  const docs: {
    table: string; lineTable: string; fk: string;
    controlPrefix: string; controlSide: 'debit' | 'credit';
    vatDescription: string; vatSide: 'debit' | 'credit';
  }[] = [
    { table: 'sales_invoices', lineTable: 'sales_invoice_lines', fk: 'invoice_id', controlPrefix: 'فاتورة مبيعات رقم ', controlSide: 'debit', vatDescription: 'ضريبة قيمة مضافة على المبيعات', vatSide: 'credit' },
    { table: 'purchase_invoices', lineTable: 'purchase_invoice_lines', fk: 'invoice_id', controlPrefix: 'فاتورة مشتريات رقم ', controlSide: 'credit', vatDescription: 'ضريبة قيمة مضافة على المشتريات', vatSide: 'debit' },
    { table: 'sales_returns', lineTable: 'sales_return_lines', fk: 'return_id', controlPrefix: 'مرجع مبيعات رقم ', controlSide: 'credit', vatDescription: 'عكس ضريبة مخرجات — مرجع مبيعات', vatSide: 'debit' },
    { table: 'purchase_returns', lineTable: 'purchase_return_lines', fk: 'return_id', controlPrefix: 'مرجع مشتريات رقم ', controlSide: 'debit', vatDescription: 'عكس ضريبة مدخلات — مرجع مشتريات', vatSide: 'credit' },
  ];

  const perDoc: any[] = [];
  let confirmed = 0, confirmedZero = 0, unresolved = 0, roundingFlags = 0;
  const unresolvedSamples: any[] = [];

  for (const d of docs) {
    const sql = `
      with totals as (
        select h.id, h.rate, h.status, coalesce(sum(l.line_total), 0) as v_total
        from ${d.table} h
        left join ${d.lineTable} l on l.${d.fk} = h.id
        where h.org_id = $1 and h.status in ('posted', 'void')
        group by h.id, h.rate, h.status
      ),
      vat_match as (
        select h.id, round(coalesce(sum(jl.${d.vatSide}), 0) / h.rate, 4) as v_vat_matched
        from ${d.table} h
        join journal_lines jl on jl.entry_id = h.journal_entry_id and jl.description = $2
        where h.org_id = $1 and h.status in ('posted', 'void')
        group by h.id, h.rate
      ),
      control_line as (
        -- the ONE line carrying (v_total+v_vat)*rate — never the COGS/
        -- inventory mirror pair, which would otherwise pollute a naive
        -- whole-side sum. Matched by its own stable, unconditional prefix.
        select h.id, round(coalesce(sum(jl.${d.controlSide}), 0) / h.rate, 4) as v_control_total
        from ${d.table} h
        join journal_lines jl on jl.entry_id = h.journal_entry_id and jl.description like $3
        where h.org_id = $1 and h.status in ('posted', 'void')
        group by h.id, h.rate
      )
      select t.id, t.status, t.v_total, v.v_vat_matched, c.v_control_total
      from totals t
      left join vat_match v on v.id = t.id
      left join control_line c on c.id = t.id
    `;
    const rows = (await client.query(sql, [orgId, d.vatDescription, `${d.controlPrefix}%`])).rows;

    for (const r of rows) {
      const vTotal = Number(r.v_total);
      const matched = r.v_vat_matched === null ? null : Number(r.v_vat_matched);
      const control = r.v_control_total === null ? null : Number(r.v_control_total);
      let status: 'confirmed' | 'confirmed_zero' | 'unresolved';
      if (matched !== null) {
        status = 'confirmed';
        confirmed++;
        // sanity cross-check: does the matched VAT line reconcile with the
        // document's own control-line total (v_total + vat == control total)?
        if (control !== null && Math.abs(control - (vTotal + matched)) > 0.01) {
          roundingFlags++;
          perDoc.push({ table: d.table, id: r.id, status, note: 'matched VAT line does not reconcile with the control-line total — rounding drift or a co-mingled non-VAT line, review manually', v_total: vTotal, matched, control_total: control });
        }
      } else if (control !== null && Math.abs(control - vTotal) <= 0.01) {
        // no VAT line found, AND the control line's own total exactly
        // equals the line-total sum with no markup — genuinely,
        // confirmably zero tax
        status = 'confirmed_zero';
        confirmedZero++;
      } else {
        // no VAT line found, and the control line does NOT cleanly match
        // "no tax" either — cannot determine the historical rate safely
        status = 'unresolved';
        unresolved++;
        const sample = { table: d.table, id: r.id, status, v_total: vTotal, control_total: control };
        perDoc.push(sample);
        if (unresolvedSamples.length < 20) unresolvedSamples.push(sample);
      }
    }
  }

  console.log(`  tax: ${confirmed} confirmed (real VAT line found), ${confirmedZero} confirmed-zero (no VAT line, entry total reconciles to no-tax), ${unresolved} UNRESOLVED, ${roundingFlags} matched-but-reconciliation-flag`);
  if (unresolvedSamples.length) {
    console.log(`  unresolved samples (up to 20): ${unresolvedSamples.map((s) => `${s.table}:${s.id}`).join(', ')}`);
  }
  return { confirmed_count: confirmed, confirmed_zero_count: confirmedZero, unresolved_count: unresolved, reconciliation_flag_count: roundingFlags, details: perDoc };
}

// ----------------------------------------------------------------------------
// RETURN LINE LINKS — simulate 20250911004900_return_line_caps.sql's own
// backfill (link only where {invoice_id,item_id} resolves to exactly one
// line), and additionally classify by document status.
// ----------------------------------------------------------------------------
async function returnLinksSection(client: pg.PoolClient, orgId: string) {
  const sides: { table: string; lineTable: string; retFk: string; invFk: string; invLineTable: string }[] = [
    { table: 'sales_returns', lineTable: 'sales_return_lines', retFk: 'return_id', invFk: 'sales_invoice_id', invLineTable: 'sales_invoice_lines' },
    { table: 'purchase_returns', lineTable: 'purchase_return_lines', retFk: 'return_id', invFk: 'purchase_invoice_id', invLineTable: 'purchase_invoice_lines' },
  ];

  let resolvable = 0, ambiguous = 0;
  const byStatus: Record<string, number> = { draft: 0, posted: 0, void: 0 };
  const ambiguousSamples: any[] = [];

  for (const s of sides) {
    const sql = `
      select rl.id as return_line_id, r.status,
        (select count(*) from ${s.invLineTable} il where il.invoice_id = r.${s.invFk} and il.item_id = rl.item_id) as candidate_count
      from ${s.lineTable} rl
      join ${s.table} r on r.id = rl.${s.retFk}
      where r.org_id = $1
    `;
    const rows = (await client.query(sql, [orgId])).rows;
    for (const row of rows) {
      byStatus[row.status] = (byStatus[row.status] ?? 0) + 1;
      if (Number(row.candidate_count) === 1) resolvable++;
      else {
        ambiguous++;
        if (ambiguousSamples.length < 20) ambiguousSamples.push({ table: s.lineTable, return_line_id: row.return_line_id, status: row.status, candidate_count: Number(row.candidate_count) });
      }
    }
  }

  console.log(`  return links: ${resolvable} resolvable to a single original line, ${ambiguous} ambiguous (item repeats on the original invoice — left NULL, never guessed); by status: ${JSON.stringify(byStatus)}`);
  return { resolvable_count: resolvable, ambiguous_count: ambiguous, by_status: byStatus, ambiguous_samples: ambiguousSamples };
}

// ----------------------------------------------------------------------------
// INVENTORY — GL inventory account value vs. sum(item_warehouse_balances),
// per warehouse/account; plus data-sanity red flags (negative qty/value,
// nonsensical average cost).
// ----------------------------------------------------------------------------
async function inventorySection(client: pg.PoolClient, orgId: string) {
  const glVsSubledger = (await client.query(
    `
    select a.id as account_id, a.code, a.name_ar,
      coalesce((
        select sum(jl.debit) - sum(jl.credit)
        from journal_lines jl join journal_entries je on je.id = jl.entry_id
        where jl.account_id = a.id and je.org_id = $1 and je.status = 'posted'
      ), 0) as gl_value,
      coalesce((
        select sum(iwb.qty * iwb.avg_cost)
        from item_warehouse_balances iwb join items it on it.id = iwb.item_id
        where it.inventory_account_id = a.id and it.org_id = $1
      ), 0) as subledger_value
    from accounts a
    where a.org_id = $1 and exists (select 1 from items it where it.inventory_account_id = a.id and it.org_id = $1)
    `,
    [orgId],
  )).rows;

  const diffs = glVsSubledger.map((r: any) => ({
    account_id: r.account_id, code: r.code, name_ar: r.name_ar,
    gl_value: Number(r.gl_value), subledger_value: Number(r.subledger_value),
    diff: round4(Number(r.gl_value) - Number(r.subledger_value)),
  }));
  const materialDiffs = diffs.filter((d) => Math.abs(d.diff) > 0.01);

  const negQty = (await client.query(
    `select iwb.item_id, it.code, iwb.warehouse_id, iwb.qty
     from item_warehouse_balances iwb join items it on it.id = iwb.item_id
     where it.org_id = $1 and iwb.qty < 0`,
    [orgId],
  )).rows;
  const negValue = (await client.query(
    `select iwb.item_id, it.code, iwb.warehouse_id, iwb.qty, iwb.avg_cost, (iwb.qty * iwb.avg_cost) as value
     from item_warehouse_balances iwb join items it on it.id = iwb.item_id
     where it.org_id = $1 and iwb.avg_cost < 0`,
    [orgId],
  )).rows;

  console.log(`  inventory: ${materialDiffs.length} account(s) with GL != sub-ledger (>0.01), ${negQty.length} negative-qty rows, ${negValue.length} negative-avg-cost rows`);
  for (const d of materialDiffs) console.log(`    ${d.code} ${d.name_ar}: GL=${d.gl_value} sub-ledger=${d.subledger_value} diff=${d.diff}`);

  // purchase-return drift the new cost-consistency migration cannot retroactively fix:
  // any purchase_return posted BEFORE this migration whose item's average had already
  // drifted from the original receiving cost at the time it was posted (informational —
  // this is a historical fact, not something today's data can re-derive precisely without
  // replaying the whole cost history; flagged so a manual GL reconciliation can decide).
  const preExistingPurchaseReturns = (await client.query(
    `select count(*)::int as n from purchase_returns where org_id = $1 and status in ('posted','void')`,
    [orgId],
  )).rows[0]?.n ?? 0;

  return {
    gl_vs_subledger: diffs,
    material_diff_count: materialDiffs.length,
    negative_qty_count: negQty.length,
    negative_qty_samples: negQty.slice(0, 20),
    negative_value_count: negValue.length,
    negative_value_samples: negValue.slice(0, 20),
    pre_existing_purchase_returns_not_retroactively_fixed: preExistingPurchaseReturns,
  };
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}

main().catch((e) => {
  console.error('PREFLIGHT SCRIPT ERROR:', e);
  process.exit(1);
});
