import { pool } from './target.ts';
import { q, closeLegacy } from './legacy.ts';
import { env } from './env.ts';

/** Compare row counts and check tree integrity after a load. */
async function main() {
  const org = (await pool.query(`select id from organizations where code = $1`, [env.org.code])).rows[0]?.id;
  if (!org) throw new Error(`org ${env.org.code} not found`);

  const checks: [string, number, number][] = [];

  const legacyAccounts = (await q<{ n: number }>(`SELECT COUNT(*) n FROM master_acc WHERE ISNULL(delete_flage,0)=0`))[0].n;
  const ourAccounts = (await pool.query(`select count(*)::int n from accounts where org_id = $1`, [org])).rows[0].n;
  checks.push(['accounts', legacyAccounts, ourAccounts]);

  const legacyDealers = (await q<{ n: number }>(`SELECT COUNT(DISTINCT Dealer_no) n FROM Dealers_tb`))[0].n;
  const ourDealers = (await pool.query(`select count(*)::int n from dealers where org_id = $1`, [org])).rows[0].n;
  checks.push(['dealers (distinct)', legacyDealers, ourDealers]);

  console.log('  table            legacy   rotopa   ok');
  let ok = true;
  for (const [name, a, b] of checks) {
    const good = b >= a * 0.98; // allow small skips (logged during load)
    ok &&= good;
    console.log(`  ${name.padEnd(16)} ${String(a).padStart(6)} ${String(b).padStart(8)}   ${good ? '✓' : '✗'}`);
  }

  // tree integrity
  const orphans = (await pool.query(
    `select count(*)::int n from accounts c
       where c.org_id = $1 and c.parent_id is not null
         and not exists (select 1 from accounts p where p.id = c.parent_id)`,
    [org],
  )).rows[0].n;
  const badLeaf = (await pool.query(
    `select count(*)::int n from accounts p
       where p.org_id = $1 and p.is_postable
         and exists (select 1 from accounts c where c.parent_id = p.id)`,
    [org],
  )).rows[0].n;
  console.log(`  orphan accounts: ${orphans} ${orphans ? '✗' : '✓'}`);
  console.log(`  postable-with-children: ${badLeaf} ${badLeaf ? '✗' : '✓'}`);

  if (!ok || orphans || badLeaf) process.exitCode = 1;
}

main()
  .catch((e) => { console.error('✗', e.message); process.exitCode = 1; })
  .finally(async () => { await closeLegacy(); await pool.end(); });
