import { provisionOrg, pool } from './target.ts';
import { closeLegacy } from './legacy.ts';
import { migrateCurrencies } from './steps/currencies.ts';
import { migrateCategories } from './steps/categories.ts';
import { migrateAccounts } from './steps/accounts.ts';
import { categorizeAccounts } from './steps/categorize-accounts.ts';
import { migrateRates } from './steps/rates.ts';
import { migrateDealers } from './steps/dealers.ts';
import { migrateInventory } from './steps/inventory.ts';
import { migrateOpeningStock } from './steps/opening-stock.ts';
import { migrateOpeningBalances } from './steps/opening-balances.ts';

const STEPS: Record<string, (orgId: string) => Promise<void>> = {
  currencies: migrateCurrencies,
  categories: migrateCategories,
  accounts: migrateAccounts,
  'categorize-accounts': categorizeAccounts,
  rates: migrateRates,
  dealers: migrateDealers,
  inventory: migrateInventory,
  'opening-stock': migrateOpeningStock,
  'opening-balances': migrateOpeningBalances,
};
// categorize-accounts runs LAST: inventory (COGS-DEFAULT/INV-DEFAULT) and
// opening-balances (OB-VAR/RE) each create their own fallback accounts on
// demand, after the accounts step itself has already run — categorizing
// any earlier would leave exactly those 4 system accounts uncategorized,
// the same gap this step exists to close in the first place.
const ORDER = ['currencies', 'categories', 'accounts', 'rates', 'dealers', 'inventory', 'opening-stock', 'opening-balances', 'categorize-accounts'];

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
