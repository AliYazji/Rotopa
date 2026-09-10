import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';

interface Acc {
  id: string;
  code: string;
  name_ar: string;
  parent_id: string | null;
  depth: number;
  is_postable: boolean;
  nature: string;
  path: string;
}

const NATURE: Record<string, string> = { debit: 'مدين', credit: 'دائن', both: 'مدين/دائن' };

export default function Accounts() {
  const { org } = useOrg();
  const [q, setQ] = useState('');
  const { data, isLoading } = useQuery({
    queryKey: ['accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Acc[]> => {
      const { data, error } = await supabase
        .from('accounts')
        .select('id, code, name_ar, parent_id, depth, is_postable, nature, path')
        .order('path');
      if (error) throw error;
      return data as Acc[];
    },
  });

  const rows = useMemo(() => {
    if (!data) return [];
    if (!q.trim()) return data;
    const needle = q.trim();
    return data.filter((a) => a.name_ar.includes(needle) || a.code.includes(needle));
  }, [data, q]);

  return (
    <>
      <h1>دليل الحسابات</h1>
      <div className="field" style={{ maxWidth: 320 }}>
        <input placeholder="بحث بالاسم أو الرقم…" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 110 }}>الرمز</th>
              <th>الاسم</th>
              <th style={{ width: 90 }}>الطبيعة</th>
              <th style={{ width: 80 }}>النوع</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={4} className="muted">جارٍ التحميل…</td></tr>}
            {rows.map((a) => (
              <tr key={a.id}>
                <td className="mono">{a.code}</td>
                <td style={{ paddingInlineStart: `${(q ? 0 : a.depth) * 1.4 + 0.7}rem` }}>
                  {a.is_postable ? a.name_ar : <strong>{a.name_ar}</strong>}
                </td>
                <td className="muted">{NATURE[a.nature]}</td>
                <td>
                  <span className="badge">{a.is_postable ? 'ترحيل' : 'تجميع'}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted" style={{ fontSize: '0.85rem' }}>{rows.length} حساب</p>
    </>
  );
}
