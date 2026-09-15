import { createContext, useContext, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from './supabase.ts';

export interface Org {
  id: string;
  code: string;
  name_ar: string;
  base_currency_id: string;
}

interface TaxSettings { enabled: boolean; rate: number; }

export interface DefaultAccounts {
  salesAccountId: string;
  outputVatAccountId: string;
  inputVatAccountId: string;
  cashAccountId: string;
}

interface OrgState {
  org: Org | null;
  loading: boolean;
  refetch: () => void;
  /** effective VAT rate: 0 whenever tax is disabled, whatever the configured rate is */
  taxRate: number;
  taxEnabled: boolean;
  refetchTax: () => void;
  /** org-level default posting accounts (settings > الحسابات الافتراضية) — a
   * starting point to pre-fill posting forms with, never a hard requirement;
   * each field is '' when unset. */
  defaultAccounts: DefaultAccounts;
  refetchDefaultAccounts: () => void;
}

const DEFAULT_TAX: TaxSettings = { enabled: true, rate: 0.16 };
const EMPTY_DEFAULT_ACCOUNTS: DefaultAccounts = { salesAccountId: '', outputVatAccountId: '', inputVatAccountId: '', cashAccountId: '' };

const Ctx = createContext<OrgState>({
  org: null, loading: true, refetch: () => {},
  taxRate: DEFAULT_TAX.rate, taxEnabled: DEFAULT_TAX.enabled, refetchTax: () => {},
  defaultAccounts: EMPTY_DEFAULT_ACCOUNTS, refetchDefaultAccounts: () => {},
});

export function OrgProvider({ children }: { children: ReactNode }) {
  const { data, isLoading, refetch } = useQuery({
    queryKey: ['my-org'],
    queryFn: async (): Promise<Org | null> => {
      // RLS returns only orgs the signed-in user is a member of.
      const { data, error } = await supabase
        .from('organizations')
        .select('id, code, name_ar, base_currency_id')
        .limit(1);
      if (error) throw error;
      return data?.[0] ?? null;
    },
  });

  const org = data ?? null;

  const { data: tax, refetch: refetchTax } = useQuery({
    queryKey: ['org-tax-settings', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<TaxSettings> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'tax').maybeSingle();
      if (error) throw error;
      return (data?.value as TaxSettings) ?? DEFAULT_TAX;
    },
  });

  const taxEnabled = tax?.enabled ?? DEFAULT_TAX.enabled;
  const taxRate = taxEnabled ? (tax?.rate ?? DEFAULT_TAX.rate) : 0;

  const { data: defaultAccountsRow, refetch: refetchDefaultAccounts } = useQuery({
    queryKey: ['org-default-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<DefaultAccounts> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'default_accounts').maybeSingle();
      if (error) throw error;
      const v = (data?.value ?? {}) as Record<string, string | null>;
      return {
        salesAccountId: v.sales_account_id ?? '',
        outputVatAccountId: v.output_vat_account_id ?? '',
        inputVatAccountId: v.input_vat_account_id ?? '',
        cashAccountId: v.cash_account_id ?? '',
      };
    },
  });

  return (
    <Ctx.Provider value={{
      org, loading: isLoading, refetch, taxRate, taxEnabled, refetchTax: () => refetchTax(),
      defaultAccounts: defaultAccountsRow ?? EMPTY_DEFAULT_ACCOUNTS, refetchDefaultAccounts: () => refetchDefaultAccounts(),
    }}>{children}</Ctx.Provider>
  );
}

export const useOrg = () => useContext(Ctx);
