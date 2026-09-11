import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney } from '../lib/format.ts';

interface Item {
  id: string; code: string; name_ar: string; name_en: string | null; base_unit_name: string;
  sales_price: number; is_stock_tracked: boolean; barcode: string | null;
  category_id: string | null; inventory_account_id: string | null; cogs_account_id: string | null;
  min_stock: number | null; max_stock: number | null; is_active: boolean; notes: string | null;
}
interface CatOpt { id: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }
interface Balance { warehouse: { code: string; name_ar: string }; qty: number; avg_cost: number; }
interface MoveLine {
  base_qty: number; direction: 'in' | 'out'; unit_cost: number;
  warehouse: { name_ar: string };
  move: { move_no: number; move_date: string; move_type: string; status: string; description: string };
}

const MOVE_TYPE: Record<string, string> = {
  opening: 'رصيد افتتاحي', adjustment_in: 'إضافة', adjustment_out: 'صرف',
  transfer: 'تحويل', purchase_in: 'مشتريات', sale_out: 'مبيعات',
};

export default function ItemDetail() {
  const { id } = useParams();
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState<Partial<Item>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: item, isLoading } = useQuery({
    queryKey: ['item', id],
    enabled: !!id,
    queryFn: async (): Promise<Item> => {
      const { data, error } = await supabase.from('items').select('*').eq('id', id).single();
      if (error) throw error;
      return data as Item;
    },
  });
  useEffect(() => { if (item) setForm(item); }, [item]);

  const { data: categories } = useQuery({
    queryKey: ['item-categories'],
    queryFn: async (): Promise<CatOpt[]> => {
      const { data, error } = await supabase.from('item_categories').select('id, name_ar').order('sort_order');
      if (error) throw error;
      return data as CatOpt[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts'],
    enabled: editing,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  const { data: balances } = useQuery({
    queryKey: ['item-balances', id],
    enabled: !!id,
    queryFn: async (): Promise<Balance[]> => {
      const { data, error } = await supabase.from('item_warehouse_balances')
        .select('qty, avg_cost, warehouse:warehouse_id(code, name_ar)').eq('item_id', id);
      if (error) throw error;
      return data as unknown as Balance[];
    },
  });

  const { data: history } = useQuery({
    queryKey: ['item-history', id],
    enabled: !!id,
    queryFn: async (): Promise<MoveLine[]> => {
      const { data, error } = await supabase.from('stock_move_lines')
        .select('base_qty, direction, unit_cost, warehouse:warehouse_id(name_ar), move:move_id(move_no, move_date, move_type, status, description)')
        .eq('item_id', id).order('created_at', { ascending: false }).limit(30);
      if (error) throw error;
      return (data as unknown as MoveLine[]).filter((l) => l.move.status === 'posted');
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (form.is_stock_tracked && (!form.inventory_account_id || !form.cogs_account_id)) {
        throw new Error('صنف يتتبّع المخزون يحتاج حساب مخزون وحساب تكلفة');
      }
      const { error } = await supabase.from('items').update({
        name_ar: form.name_ar, name_en: form.name_en || null,
        category_id: form.category_id || null, base_unit_name: form.base_unit_name || 'قطعة',
        sales_price: form.sales_price ?? 0, barcode: form.barcode || null,
        min_stock: form.min_stock ?? null, max_stock: form.max_stock ?? null,
        is_stock_tracked: form.is_stock_tracked,
        inventory_account_id: form.is_stock_tracked ? form.inventory_account_id : null,
        cogs_account_id: form.is_stock_tracked ? form.cogs_account_id : null,
        is_active: form.is_active, notes: form.notes || null,
      }).eq('id', id);
      if (error) throw error;
      await qc.invalidateQueries({ queryKey: ['item', id] });
      await qc.invalidateQueries({ queryKey: ['items'] });
      setEditing(false);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (isLoading || !item) return <p className="muted">جارٍ التحميل…</p>;
  const totalQty = balances?.reduce((s, b) => s + Number(b.qty), 0) ?? 0;
  const categoryName = categories?.find((c) => c.id === item.category_id)?.name_ar ?? '—';

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{item.name_ar}</h1>
        {!editing && <button onClick={() => setEditing(true)}>تعديل</button>}
      </div>
      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap', marginBottom: '1.25rem' }}>
        <div className="card" style={{ flex: '1 1 300px' }}>
          {!editing ? (
            <table>
              <tbody>
                <tr><td className="muted">الرمز</td><td className="mono">{item.code}</td></tr>
                <tr><td className="muted">الفئة</td><td>{categoryName}</td></tr>
                <tr><td className="muted">الوحدة</td><td>{item.base_unit_name}</td></tr>
                <tr><td className="muted">الباركود</td><td className="mono">{item.barcode ?? '—'}</td></tr>
                <tr><td className="muted">سعر البيع</td><td className="num">{fmtMoney(item.sales_price)}</td></tr>
                <tr><td className="muted">حد أدنى/أقصى</td><td className="num">{item.min_stock ?? '—'} / {item.max_stock ?? '—'}</td></tr>
                <tr><td className="muted">تتبّع المخزون</td><td>{item.is_stock_tracked ? 'نعم' : 'لا (صنف خدمي)'}</td></tr>
                <tr><td className="muted">نشط</td><td>{item.is_active ? 'نعم' : 'لا'}</td></tr>
                {item.notes && <tr><td className="muted">ملاحظات</td><td>{item.notes}</td></tr>}
              </tbody>
            </table>
          ) : (
            <>
              <div className="row">
                <div className="field grow">
                  <label>الاسم</label>
                  <input value={form.name_ar ?? ''} onChange={(e) => setForm({ ...form, name_ar: e.target.value })} />
                </div>
                <div className="field" style={{ width: 130 }}>
                  <label>الباركود</label>
                  <input value={form.barcode ?? ''} onChange={(e) => setForm({ ...form, barcode: e.target.value })} dir="ltr" />
                </div>
              </div>
              <div className="row">
                <div className="field grow">
                  <label>الفئة</label>
                  <select value={form.category_id ?? ''} onChange={(e) => setForm({ ...form, category_id: e.target.value })}>
                    <option value="">—</option>
                    {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
                  </select>
                </div>
                <div className="field" style={{ width: 110 }}>
                  <label>الوحدة</label>
                  <input value={form.base_unit_name ?? ''} onChange={(e) => setForm({ ...form, base_unit_name: e.target.value })} />
                </div>
                <div className="field" style={{ width: 110 }}>
                  <label>سعر البيع</label>
                  <input className="num" inputMode="decimal" value={form.sales_price ?? 0} onChange={(e) => setForm({ ...form, sales_price: parseFloat(e.target.value) || 0 })} />
                </div>
              </div>
              <div className="row">
                <div className="field grow">
                  <label>حد أدنى للمخزون</label>
                  <input className="num" inputMode="decimal" value={form.min_stock ?? ''} onChange={(e) => setForm({ ...form, min_stock: e.target.value ? parseFloat(e.target.value) : null })} />
                </div>
                <div className="field grow">
                  <label>حد أقصى للمخزون</label>
                  <input className="num" inputMode="decimal" value={form.max_stock ?? ''} onChange={(e) => setForm({ ...form, max_stock: e.target.value ? parseFloat(e.target.value) : null })} />
                </div>
              </div>
              <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', margin: '0.5rem 0' }}>
                <input type="checkbox" style={{ width: 'auto' }} checked={form.is_stock_tracked ?? true} onChange={(e) => setForm({ ...form, is_stock_tracked: e.target.checked })} />
                يتتبّع المخزون
              </label>
              {form.is_stock_tracked && (
                <div className="row">
                  <div className="field grow">
                    <label>حساب المخزون</label>
                    <select value={form.inventory_account_id ?? ''} onChange={(e) => setForm({ ...form, inventory_account_id: e.target.value })}>
                      <option value="">—</option>
                      {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                    </select>
                  </div>
                  <div className="field grow">
                    <label>حساب تكلفة البضاعة</label>
                    <select value={form.cogs_account_id ?? ''} onChange={(e) => setForm({ ...form, cogs_account_id: e.target.value })}>
                      <option value="">—</option>
                      {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                    </select>
                  </div>
                </div>
              )}
              <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', margin: '0.5rem 0' }}>
                <input type="checkbox" style={{ width: 'auto' }} checked={form.is_active ?? true} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
                نشط
              </label>
              <div className="field">
                <label>ملاحظات</label>
                <input value={form.notes ?? ''} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
              </div>
              {err && <p className="error">{err}</p>}
              <div className="row">
                <button className="btn-primary" disabled={busy} onClick={save}>حفظ</button>
                <button disabled={busy} onClick={() => { setForm(item); setEditing(false); setErr(null); }}>إلغاء</button>
              </div>
            </>
          )}
        </div>
        {item.is_stock_tracked && !editing && (
          <div className="card" style={{ flex: '1 1 200px', display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center' }}>
            <div className="muted" style={{ fontSize: '0.85rem' }}>الرصيد الحالي</div>
            <div style={{ fontSize: '1.8rem', fontWeight: 700, fontFamily: 'var(--mono)' }}>{fmtMoney(totalQty)}</div>
            <div className="muted" style={{ fontSize: '0.85rem' }}>{item.base_unit_name}</div>
          </div>
        )}
      </div>

      {item.is_stock_tracked && !editing && (
        <>
          <h2>الرصيد حسب المستودع</h2>
          <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1.25rem' }}>
            <table>
              <thead><tr><th>المستودع</th><th className="num" style={{ width: 120 }}>الكمية</th><th className="num" style={{ width: 120 }}>متوسط التكلفة</th></tr></thead>
              <tbody>
                {(!balances || balances.length === 0) && <tr><td colSpan={3} className="muted">لا رصيد بعد.</td></tr>}
                {balances?.filter((b) => Number(b.qty) !== 0).map((b, i) => (
                  <tr key={i}><td>{b.warehouse.name_ar}</td><td className="num">{fmtMoney(b.qty)}</td><td className="num">{fmtMoney(b.avg_cost)}</td></tr>
                ))}
              </tbody>
            </table>
          </div>

          <h2>حركة المخزون</h2>
          <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
            <table>
              <thead>
                <tr><th style={{ width: 90 }}>التاريخ</th><th style={{ width: 100 }}>النوع</th><th>المستودع</th><th className="num" style={{ width: 100 }}>وارد</th><th className="num" style={{ width: 100 }}>صادر</th></tr>
              </thead>
              <tbody>
                {(!history || history.length === 0) && <tr><td colSpan={5} className="muted">لا حركات بعد.</td></tr>}
                {history?.map((l, i) => (
                  <tr key={i}>
                    <td>{fmtDate(l.move.move_date)}</td>
                    <td>{MOVE_TYPE[l.move.move_type] ?? l.move.move_type}</td>
                    <td>{l.warehouse.name_ar}</td>
                    <td className="num">{l.direction === 'in' ? fmtMoney(l.base_qty) : ''}</td>
                    <td className="num">{l.direction === 'out' ? fmtMoney(l.base_qty) : ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
