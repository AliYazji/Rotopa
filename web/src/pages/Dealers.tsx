import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';

interface Dealer {
  id: string;
  code: string;
  name_ar: string;
  is_customer: boolean;
  is_supplier: boolean;
  is_employee: boolean;
  phone: string | null;
  city: string | null;
  is_active: boolean;
}

type RoleFilter = 'all' | 'customer' | 'supplier' | 'employee';

export default function Dealers() {
  const { org } = useOrg();
  const [q, setQ] = useState('');
  const [role, setRole] = useState<RoleFilter>('all');

  const { data, isLoading } = useQuery({
    queryKey: ['dealers', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Dealer[]> => {
      const { data, error } = await supabase
        .from('dealers')
        .select('id, code, name_ar, is_customer, is_supplier, is_employee, phone, city, is_active')
        .order('name_ar');
      if (error) throw error;
      return data as Dealer[];
    },
  });

  const rows = useMemo(() => {
    let r = data ?? [];
    if (role !== 'all') r = r.filter((d) => (role === 'customer' ? d.is_customer : role === 'supplier' ? d.is_supplier : d.is_employee));
    if (q.trim()) r = r.filter((d) => d.name_ar.includes(q) || d.code.includes(q) || (d.phone ?? '').includes(q));
    return r;
  }, [data, q, role]);

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>العملاء والموردون</h1>
        <Link to="/dealers/new" className="btn btn-primary">طرف جديد</Link>
      </div>
      <div className="row" style={{ marginBottom: '1rem', flexWrap: 'wrap', gap: '0.75rem' }}>
        <input placeholder="بحث بالاسم أو الرقم أو الهاتف…" value={q} onChange={(e) => setQ(e.target.value)} style={{ maxWidth: 280 }} />
        <select value={role} onChange={(e) => setRole(e.target.value as RoleFilter)} style={{ width: 140 }}>
          <option value="all">الكل</option>
          <option value="customer">عملاء</option>
          <option value="supplier">موردون</option>
          <option value="employee">موظفون</option>
        </select>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 100 }}>الرمز</th>
              <th>الاسم</th>
              <th style={{ width: 150 }}>الأدوار</th>
              <th style={{ width: 130 }}>الهاتف</th>
              <th style={{ width: 110 }}>المدينة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {rows.length === 0 && !isLoading && <tr><td colSpan={5} className="muted">لا نتائج.</td></tr>}
            {rows.map((d) => (
              <tr key={d.id}>
                <td className="mono">{d.code}</td>
                <td><Link to={`/dealers/${d.id}`}>{d.name_ar}</Link></td>
                <td>
                  {d.is_customer && <span className="badge">عميل</span>}{' '}
                  {d.is_supplier && <span className="badge">مورد</span>}{' '}
                  {d.is_employee && <span className="badge">موظف</span>}
                </td>
                <td className="mono">{d.phone}</td>
                <td>{d.city}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted" style={{ fontSize: '0.85rem' }}>{rows.length} طرف</p>
    </>
  );
}
