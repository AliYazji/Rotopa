import { provisionOrg, pool } from './target.ts';
import { closeLegacy } from './legacy.ts';
import { migrateCurrencies } from './steps/currencies.ts';
import { migrateCategories } from './steps/categories.ts';
import { migrateAccounts } from './steps/accounts.ts';
import { migrateRates } from './steps/rates.ts';
import { migrateDealers } from './steps/dealers.ts';

const STEPS: Record<string, (orgId: string) => Promise<void>> = {
  currencies: migrateCurrencies,
  categories: migrateCategories,
  accounts: migrateAccounts,
  rates: migrateRates,
  dealers: migrateDealers,
};
const ORDER = ['currencies', 'categories', 'accounts', 'rates', 'dealers'];

async function main() {
  const want = process.argv.slice(2);
  const steps = want.length ? want : ORDER;
  for (const s of steps) if (!STEPS[s]) throw new Error(`unknown step "${s}" (have: ${ORDER.join(', ')})`);

  console.log('→ provisioning organization');
  const { orgId } = await provisionOrg();
  console.log(`  org ${orgId}`);

  for (const s of steps) {
    console.log(`→ ${s}`);
    await STEPS[s]!(orgId);
  }

  console.log('✓ done');
}

main()
  .catch((e) => {
    console.error('✗', e.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await closeLegacy();
    await pool.end();
  });
