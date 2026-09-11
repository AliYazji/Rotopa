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
}

/**
 * One shared party record can be a customer, a supplier, an employee, or any
 * combination (the same real-world entity, not a duplicated record per
 * role — see create_dealer()). This component is the reusable list; the
 * pages that route to it (Customers/Suppliers/Employees) just fix which role
 * they show, matching how an accountant actually thinks about these lists.
 * A party in more than one role appears — correctly — on more than one page.
 */
export function DealerList({
  roleKey,
  title,
  newLabel,
}: {
  roleKey: 'is_customer' | 'is_supplier' | 'is_employee';
  title: string;
  newLabel: string;
}) {
  const { org } = useOrg();
  const [q, setQ] = useState('');

  const { data, isLoading } = useQuery({
    queryKey: ['dealers', org?.id, roleKey],
    enabled: !!org,
    queryFn: async (): Promise<Dealer[]> => {
      const { data, error } = await supabase
        .from('dealers')
        .select('id, code, name_ar, is_customer, is_supplier, is_employee, phone, city')
        .eq(roleKey, true)
        .order('name_ar');
      if (error) throw error;
      return data as Dealer[];
    },
  });

  const rows = useMemo(() => {
    const r = data ?? [];
    if (!q.trim()) return r;
    return r.filter((d) => d.name_ar.includes(q) || d.code.includes(q) || (d.phone ?? '').includes(q));
  }, [data, q]);

  const otherRoles = (d: Dealer) => {
    const others: string[] = [];
    if (roleKey !== 'is_customer' && d.is_customer) others.push('عميل');
    if (roleKey !== 'is_supplier' && d.is_supplier) others.push('مورد');
    if (roleKey !== 'is_employee' && d.is_employee) others.push('موظف');
    return others;
  };

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{title}</h1>
        <Link to={`/dealers/new?role=${roleKey}`} className="btn btn-primary">{newLabel}</Link>
      </div>
      <div className="field" style={{ maxWidth: 300, marginBottom: '1rem' }}>
        <input placeholder="بحث بالاسم أو الرقم أو الهاتف…" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 100 }}>الرمز</th>
              <th>الاسم</th>
              <th style={{ width: 150 }}>أدوار أخرى</th>
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
                <td>{otherRoles(d).map((r) => <span key={r} className="badge">{r}</span>)}</td>
                <td className="mono">{d.phone}</td>
                <td>{d.city}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted" style={{ fontSize: '0.85rem' }}>{rows.length}</p>
    </>
  );
}
