import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney, translateError } from '../lib/format.ts';

interface Dealer {
  id: string;
  code: string;
  name_ar: string;
  is_customer: boolean;
  is_supplier: boolean;
  is_employee: boolean;
  account_id: string;
  phone: string | null;
  email: string | null;
  address: string | null;
  city: string | null;
  tax_no: string | null;
  credit_limit: number;
  is_active: boolean;
}
interface LedgerRow {
  entry_no: number;
  entry_date: string;
  description: string;
  debit: number;
  credit: number;
  running: number;
}

export default function DealerDetail() {
  const { id } = useParams();
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState<Partial<Dealer>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: dealer, isLoading: loadingDealer } = useQuery({
    queryKey: ['dealer', id],
    enabled: !!id,
    queryFn: async (): Promise<Dealer> => {
      const { data, error } = await supabase.from('dealers').select('*').eq('id', id).single();
      if (error) throw error;
      return data as Dealer;
    },
  });
  useEffect(() => { if (dealer) setForm(dealer); }, [dealer]);

  const { data: ledger, isLoading: loadingLedger } = useQuery({
    queryKey: ['dealer-ledger', dealer?.account_id],
    enabled: !!dealer?.account_id,
    queryFn: async (): Promise<LedgerRow[]> => {
      const { data, error } = await supabase.rpc('account_ledger', { p_account_id: dealer!.account_id });
      if (error) throw error;
      return data as LedgerRow[];
    },
  });

  const { data: balance } = useQuery({
    queryKey: ['dealer-balance', dealer?.account_id],
    enabled: !!dealer?.account_id,
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('account_balance', { p_account_id: dealer!.account_id });
      if (error) throw error;
      return data as number;
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (!form.is_customer && !form.is_supplier && !form.is_employee) throw new Error('اختر دوراً واحداً على الأقل');
      const { error } = await supabase.from('dealers').update({
        name_ar: form.name_ar,
        is_customer: form.is_customer, is_supplier: form.is_supplier, is_employee: form.is_employee,
        phone: form.phone || null, email: form.email || null, address: form.address || null,
        city: form.city || null, tax_no: form.tax_no || null,
        credit_limit: form.credit_limit ?? 0, is_active: form.is_active,
      }).eq('id', id);
      if (error) throw error;
      await qc.invalidateQueries({ queryKey: ['dealer', id] });
      await qc.invalidateQueries({ queryKey: ['dealers'] });
      setEditing(false);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  if (loadingDealer || !dealer) return <p className="muted">جارٍ التحميل…</p>;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{dealer.name_ar}</h1>
        {!editing && <button onClick={() => setEditing(true)}>تعديل</button>}
      </div>
      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap', marginBottom: '1.25rem' }}>
        <div className="card" style={{ flex: '1 1 280px' }}>
          {!editing ? (
            <table>
              <tbody>
                <tr><td className="muted">الرمز</td><td className="mono">{dealer.code}</td></tr>
                <tr><td className="muted">الأدوار</td><td>
                  {dealer.is_customer && <span className="badge">عميل</span>}{' '}
                  {dealer.is_supplier && <span className="badge">مورد</span>}{' '}
                  {dealer.is_employee && <span className="badge">موظف</span>}
                </td></tr>
                <tr><td className="muted">الهاتف</td><td className="mono">{dealer.phone || '—'}</td></tr>
                <tr><td className="muted">البريد</td><td className="mono">{dealer.email || '—'}</td></tr>
                <tr><td className="muted">المدينة</td><td>{dealer.city || '—'}</td></tr>
                <tr><td className="muted">العنوان</td><td>{dealer.address || '—'}</td></tr>
                <tr><td className="muted">الرقم الضريبي</td><td className="mono">{dealer.tax_no || '—'}</td></tr>
                <tr><td className="muted">حد الائتمان</td><td className="num">{fmtMoney(dealer.credit_limit)}</td></tr>
                <tr><td className="muted">نشط</td><td>{dealer.is_active ? 'نعم' : 'لا'}</td></tr>
              </tbody>
            </table>
          ) : (
            <>
              <div className="field">
                <label>الاسم</label>
                <input value={form.name_ar ?? ''} onChange={(e) => setForm({ ...form, name_ar: e.target.value })} />
              </div>
              <div className="field">
                <label>الأدوار</label>
                <div className="row" style={{ gap: '1.25rem' }}>
                  <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
                    <input type="checkbox" style={{ width: 'auto' }} checked={form.is_customer ?? false} onChange={(e) => setForm({ ...form, is_customer: e.target.checked })} /> عميل
                  </label>
                  <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
                    <input type="checkbox" style={{ width: 'auto' }} checked={form.is_supplier ?? false} onChange={(e) => setForm({ ...form, is_supplier: e.target.checked })} /> مورد
                  </label>
                  <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
                    <input type="checkbox" style={{ width: 'auto' }} checked={form.is_employee ?? false} onChange={(e) => setForm({ ...form, is_employee: e.target.checked })} /> موظف
                  </label>
                </div>
              </div>
              <div className="row">
                <div className="field grow">
                  <label>الهاتف</label>
                  <input value={form.phone ?? ''} onChange={(e) => setForm({ ...form, phone: e.target.value })} dir="ltr" />
                </div>
                <div className="field grow">
                  <label>المدينة</label>
                  <input value={form.city ?? ''} onChange={(e) => setForm({ ...form, city: e.target.value })} />
                </div>
              </div>
              <div className="row">
                <div className="field grow">
                  <label>البريد الإلكتروني</label>
                  <input value={form.email ?? ''} onChange={(e) => setForm({ ...form, email: e.target.value })} dir="ltr" />
                </div>
                <div className="field" style={{ width: 150 }}>
                  <label>حد الائتمان</label>
                  <input className="num" inputMode="decimal" value={form.credit_limit ?? 0} onChange={(e) => setForm({ ...form, credit_limit: parseFloat(e.target.value) || 0 })} />
                </div>
              </div>
              <div className="row">
                <div className="field grow">
                  <label>العنوان</label>
                  <input value={form.address ?? ''} onChange={(e) => setForm({ ...form, address: e.target.value })} />
                </div>
                <div className="field grow">
                  <label>الرقم الضريبي</label>
                  <input value={form.tax_no ?? ''} onChange={(e) => setForm({ ...form, tax_no: e.target.value })} dir="ltr" />
                </div>
              </div>
              <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', margin: '0.5rem 0' }}>
                <input type="checkbox" style={{ width: 'auto' }} checked={form.is_active ?? true} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
                نشط
              </label>
              {err && <p className="error">{err}</p>}
              <div className="row">
                <button className="btn-primary" disabled={busy} onClick={save}>حفظ</button>
                <button disabled={busy} onClick={() => { setForm(dealer); setEditing(false); setErr(null); }}>إلغاء</button>
              </div>
            </>
          )}
        </div>
        <div className="card" style={{ flex: '1 1 200px', display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center' }}>
          <div className="muted" style={{ fontSize: '0.85rem' }}>الرصيد الحالي</div>
          <div style={{ fontSize: '1.8rem', fontWeight: 700, fontFamily: 'var(--mono)', color: (balance ?? 0) >= 0 ? 'var(--debit)' : 'var(--credit)' }}>
            {fmtMoney(Math.abs(balance ?? 0))}
          </div>
          <div className="muted" style={{ fontSize: '0.85rem' }}>{(balance ?? 0) >= 0 ? 'مدين (له/علينا)' : 'دائن (منه)'}</div>
        </div>
      </div>

      <h2>كشف الحساب</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>البيان</th>
              <th className="num" style={{ width: 110 }}>مدين</th>
              <th className="num" style={{ width: 110 }}>دائن</th>
              <th className="num" style={{ width: 120 }}>الرصيد</th>
            </tr>
          </thead>
          <tbody>
            {loadingLedger && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {ledger?.length === 0 && <tr><td colSpan={6} className="muted">لا حركات مرحّلة بعد.</td></tr>}
            {ledger?.map((l) => (
              <tr key={l.entry_no}>
                <td className="mono">{l.entry_no}</td>
                <td>{fmtDate(l.entry_date)}</td>
                <td>{l.description}</td>
                <td className="num">{l.debit ? fmtMoney(l.debit) : ''}</td>
                <td className="num">{l.credit ? fmtMoney(l.credit) : ''}</td>
                <td className="num">{fmtMoney(l.running)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
