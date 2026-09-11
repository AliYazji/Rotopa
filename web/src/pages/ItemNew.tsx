import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface AccOpt { id: string; code: string; name_ar: string; }
interface CatOpt { id: string; name_ar: string; }

export default function ItemNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [barcode, setBarcode] = useState('');
  const [categoryId, setCategoryId] = useState('');
  const [unitName, setUnitName] = useState('قطعة');
  const [salesPrice, setSalesPrice] = useState('');
  const [tracked, setTracked] = useState(true);
  const [invAccountId, setInvAccountId] = useState('');
  const [cogsAccountId, setCogsAccountId] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: categories } = useQuery({
    queryKey: ['item-categories', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<CatOpt[]> => {
      const { data, error } = await supabase.from('item_categories').select('id, name_ar').order('sort_order');
      if (error) throw error;
      return data as CatOpt[];
    },
  });

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (!code.trim() || !name.trim()) throw new Error('الرمز والاسم مطلوبان');
      if (tracked && (!invAccountId || !cogsAccountId)) throw new Error('صنف يتتبّع المخزون يحتاج حساب مخزون وحساب تكلفة');
      const { error } = await supabase.from('items').insert({
        org_id: org!.id,
        code, name_ar: name, barcode: barcode || null,
        category_id: categoryId || null,
        base_unit_name: unitName || 'قطعة',
        sales_price: parseFloat(salesPrice) || 0,
        is_stock_tracked: tracked,
        inventory_account_id: tracked ? invAccountId : null,
        cogs_account_id: tracked ? cogsAccountId : null,
      });
      if (error) throw error;
      nav('/items');
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>صنف جديد</h1>
      <div className="card" style={{ maxWidth: 560 }}>
        <div className="row">
          <div className="field" style={{ width: 160 }}>
            <label>الرمز</label>
            <input value={code} onChange={(e) => setCode(e.target.value)} dir="ltr" />
          </div>
          <div className="field grow">
            <label>الاسم</label>
            <input value={name} onChange={(e) => setName(e.target.value)} />
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>الفئة</label>
            <select value={categoryId} onChange={(e) => setCategoryId(e.target.value)}>
              <option value="">—</option>
              {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
            </select>
          </div>
          <div className="field" style={{ width: 130 }}>
            <label>وحدة القياس</label>
            <input value={unitName} onChange={(e) => setUnitName(e.target.value)} />
          </div>
          <div className="field" style={{ width: 130 }}>
            <label>سعر البيع</label>
            <input className="num" inputMode="decimal" value={salesPrice} onChange={(e) => setSalesPrice(e.target.value)} />
          </div>
        </div>
        <div className="field">
          <label>الباركود (اختياري)</label>
          <input value={barcode} onChange={(e) => setBarcode(e.target.value)} dir="ltr" />
        </div>

        <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', margin: '0.5rem 0' }}>
          <input type="checkbox" style={{ width: 'auto' }} checked={tracked} onChange={(e) => setTracked(e.target.checked)} />
          يتتبّع المخزون (كمية ورصيد)
        </label>

        {tracked && (
          <div className="row">
            <div className="field grow">
              <label>حساب المخزون</label>
              <select value={invAccountId} onChange={(e) => setInvAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
            <div className="field grow">
              <label>حساب تكلفة البضاعة</label>
              <select value={cogsAccountId} onChange={(e) => setCogsAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          </div>
        )}

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>حفظ</button>
      </div>
    </>
  );
}
