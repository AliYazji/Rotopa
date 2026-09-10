import { createContext, useContext, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from './supabase.ts';

export interface Org {
  id: string;
  code: string;
  name_ar: string;
  base_currency_id: string;
}

interface OrgState {
  org: Org | null;
  loading: boolean;
  refetch: () => void;
}

const Ctx = createContext<OrgState>({ org: null, loading: true, refetch: () => {} });

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

  return (
    <Ctx.Provider value={{ org: data ?? null, loading: isLoading, refetch }}>{children}</Ctx.Provider>
  );
}

export const useOrg = () => useContext(Ctx);
