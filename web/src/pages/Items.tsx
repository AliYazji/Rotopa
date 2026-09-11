import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, sanitizeSearchTerm } from '../lib/format.ts';

interface Item {
  id: string;
  code: string;
  name_ar: string;
  base_unit_name: string;
  sales_price: number;
  is_active: boolean;
  category: { name_ar: string } | null;
}
interface CatOpt { id: string; name_ar: string; }

export default function Items() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [q, setQ] = useState('');
  const [categoryId, setCategoryId] = useState('');

  const { data: categories } = useQuery({
    queryKey: ['item-categories', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<CatOpt[]> => {
      const { data, error } = await supabase.from('item_categories').select('id, name_ar').order('sort_order');
      if (error) throw error;
      return data as CatOpt[];
    },
  });

  // Server-side filter — the real catalog can run into the thousands, so we
  // never pull the whole table to the browser just to search it client-side.
  const { data: items, isLoading } = useQuery({
    queryKey: ['items', org?.id, q, categoryId],
    enabled: !!org,
    queryFn: async (): Promise<Item[]> => {
      let query = supabase
        .from('items')
        .select('id, code, name_ar, base_unit_name, sales_price, is_active, category:category_id(name_ar)')
        .order('code')
        .limit(150);
      const term = sanitizeSearchTerm(q);
      if (term) query = query.or(`name_ar.ilike.%${term}%,code.ilike.%${term}%,barcode.eq.${term}`);
      if (categoryId) query = query.eq('category_id', categoryId);
      const { data, error } = await query;
      if (error) throw error;
      return data as unknown as Item[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>الأصناف</h1>
        <Link to="/items/new" className="btn btn-primary">صنف جديد</Link>
      </div>
      <div className="row" style={{ marginBottom: '1rem', flexWrap: 'wrap', gap: '0.75rem' }}>
        <input placeholder="بحث بالاسم أو الرقم أو الباركود…" value={q} onChange={(e) => setQ(e.target.value)} style={{ maxWidth: 300 }} />
        <select value={categoryId} onChange={(e) => setCategoryId(e.target.value)} style={{ width: 180 }}>
          <option value="">كل الفئات</option>
          {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
        </select>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 100 }}>الرمز</th>
              <th>الاسم</th>
              <th style={{ width: 130 }}>الفئة</th>
              <th style={{ width: 80 }}>الوحدة</th>
              <th className="num" style={{ width: 100 }}>سعر البيع</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {items?.length === 0 && !isLoading && <tr><td colSpan={5} className="muted">لا نتائج.</td></tr>}
            {items?.map((it) => (
              <tr key={it.id} className="rowlink" onClick={() => nav(`/items/${it.id}`)}>
                <td className="mono">{it.code}</td>
                <td>{it.name_ar}</td>
                <td className="muted">{it.category?.name_ar ?? '—'}</td>
                <td>{it.base_unit_name}</td>
                <td className="num">{fmtMoney(it.sales_price)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {items && items.length >= 150 && <p className="muted" style={{ fontSize: '0.85rem' }}>أول 150 نتيجة — دقّق البحث لعرض أصناف أكتر تحديداً.</p>}
    </>
  );
}
