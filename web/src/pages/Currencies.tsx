import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';

interface Cur {
  id: string;
  code: string;
  name_ar: string;
  symbol: string | null;
  is_base: boolean;
  is_active: boolean;
}

export default function Currencies() {
  const { org } = useOrg();
  const { data, isLoading } = useQuery({
    queryKey: ['currencies', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Cur[]> => {
      const { data, error } = await supabase
        .from('currencies')
        .select('id, code, name_ar, symbol, is_base, is_active')
        .order('is_base', { ascending: false })
        .order('code');
      if (error) throw error;
      return data as Cur[];
    },
  });

  return (
    <>
      <h1>العملات</h1>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 90 }}>الرمز</th>
              <th>الاسم</th>
              <th style={{ width: 70 }}>الرمز</th>
              <th style={{ width: 90 }} />
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={4} className="muted">جارٍ التحميل…</td></tr>}
            {data?.map((c) => (
              <tr key={c.id}>
                <td className="mono">{c.code}</td>
                <td>{c.name_ar}</td>
                <td>{c.symbol}</td>
                <td>{c.is_base && <span className="badge posted">الأساس</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
