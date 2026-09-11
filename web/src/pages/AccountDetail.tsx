import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney } from '../lib/format.ts';

interface Account {
  id: string; code: string; name_ar: string; name_en: string | null;
  nature: string; is_postable: boolean; allow_transactions: boolean; is_active: boolean;
  category_id: string | null; currency_id: string | null; notes: string | null;
}
interface CatOpt { id: string; name_ar: string; }
interface CurOpt { id: string; code: string; name_ar: string; }
interface LedgerRow { entry_no: number; entry_date: string; description: string; debit: number; credit: number; running: number; }

export default function AccountDetail() {
  const { id } = useParams();
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState<Partial<Account>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: account, isLoading } = useQuery({
    queryKey: ['account', id],
    enabled: !!id,
    queryFn: async (): Promise<Account> => {
      const { data, error } = await supabase.from('accounts').select('*').eq('id', id).single();
      if (error) throw error;
      return data as Account;
    },
  });
  useEffect(() => { if (account) setForm(account); }, [account]);

  const { data: categories } = useQuery({
    queryKey: ['account-categories'],
    queryFn: async (): Promise<CatOpt[]> => {
      const { data, error } = await supabase.from('account_categories').select('id, name_ar').order('sort_order');
      if (error) throw error;
      return data as CatOpt[];
    },
  });
  const { data: currencies } = useQuery({
    queryKey: ['currencies'],
    queryFn: async (): Promise<CurOpt[]> => {
      const { data, error } = await supabase.from('currencies').select('id, code, name_ar');
      if (error) throw error;
      return data as CurOpt[];
    },
  });
  const { data: ledger } = useQuery({
    queryKey: ['account-ledger', id],
    enabled: !!id && !!account?.is_postable,
    queryFn: async (): Promise<LedgerRow[]> => {
      const { data, error } = await supabase.rpc('account_ledger', { p_account_id: id });
      if (error) throw error;
      return data as LedgerRow[];
    },
  });
  const { data: balance } = useQuery({
    queryKey: ['account-balance', id],
    enabled: !!id && !!account?.is_postable,
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('account_balance', { p_account_id: id });
      if (error) throw error;
      return data as number;
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      const { error } = await supabase.from('accounts').update({
        name_ar: form.name_ar, name_en: form.name_en || null, nature: form.nature,
        category_id: form.category_id || null, currency_id: form.currency_id || null,
        allow_transactions: form.allow_transactions, is_active: form.is_active,
        notes: form.notes || null,
      }).eq('id', id);
      if (error) throw error;
      await qc.invalidateQueries({ queryKey: ['account', id] });
      await qc.invalidateQueries({ queryKey: ['accounts'] });
      setEditing(false);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (isLoading || !account) return <p className="muted">جارٍ التحميل…</p>;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{account.name_ar} <span className="mono muted" style={{ fontSize: '1rem' }}>{account.code}</span></h1>
        {!editing && <button onClick={() => setEditing(true)}>تعديل</button>}
      </div>

      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap', marginBottom: '1.25rem' }}>
        <div className="card" style={{ flex: '1 1 320px' }}>
          {!editing ? (
            <table>
              <tbody>
                <tr><td className="muted">الاسم الإنجليزي</td><td>{account.name_en || '—'}</td></tr>
                <tr><td className="muted">الطبيعة</td><td>{{ debit: 'مدين', credit: 'دائن', both: 'مدين/دائن' }[account.nature]}</td></tr>
                <tr><td className="muted">النوع</td><td><span className="badge">{account.is_postable ? 'ترحيل' : 'تجميع'}</span></td></tr>
                <tr><td className="muted">التصنيف</td><td>{categories?.find((c) => c.id === account.category_id)?.name_ar ?? '—'}</td></tr>
                <tr><td className="muted">العملة المقيّدة</td><td>{currencies?.find((c) => c.id === account.currency_id)?.name_ar ?? 'أي عملة'}</td></tr>
                <tr><td className="muted">يقبل حركات</td><td>{account.allow_transactions ? 'نعم' : 'لا (موقوف)'}</td></tr>
                <tr><td className="muted">نشط</td><td>{account.is_active ? 'نعم' : 'لا'}</td></tr>
                <tr><td className="muted">ملاحظات</td><td>{account.notes || '—'}</td></tr>
              </tbody>
            </table>
          ) : (
            <>
              <div className="field">
                <label>الاسم</label>
                <input value={form.name_ar ?? ''} onChange={(e) => setForm({ ...form, name_ar: e.target.value })} />
              </div>
              <div className="field">
                <label>الاسم الإنجليزي</label>
                <input value={form.name_en ?? ''} onChange={(e) => setForm({ ...form, name_en: e.target.value })} dir="ltr" />
              </div>
              <div className="row">
                <div className="field grow">
                  <label>الطبيعة</label>
                  <select value={form.nature ?? 'both'} onChange={(e) => setForm({ ...form, nature: e.target.value })}>
                    <option value="debit">مدين</option><option value="credit">دائن</option><option value="both">مدين/دائن</option>
                  </select>
                </div>
                <div className="field grow">
                  <label>التصنيف</label>
                  <select value={form.category_id ?? ''} onChange={(e) => setForm({ ...form, category_id: e.target.value })}>
                    <option value="">—</option>
                    {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
                  </select>
                </div>
              </div>
              {account.is_postable && (
                <div className="field">
                  <label>العملة المقيّدة</label>
                  <select value={form.currency_id ?? ''} onChange={(e) => setForm({ ...form, currency_id: e.target.value })}>
                    <option value="">أي عملة</option>
                    {currencies?.map((c) => <option key={c.id} value={c.id}>{c.code} · {c.name_ar}</option>)}
                  </select>
                </div>
              )}
              <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', margin: '0.5rem 0' }}>
                <input type="checkbox" style={{ width: 'auto' }} checked={form.allow_transactions ?? true} onChange={(e) => setForm({ ...form, allow_transactions: e.target.checked })} />
                يقبل حركات جديدة
              </label>
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
                <button disabled={busy} onClick={() => { setForm(account); setEditing(false); setErr(null); }}>إلغاء</button>
              </div>
            </>
          )}
        </div>
        {account.is_postable && (
          <div className="card" style={{ flex: '1 1 200px', display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center' }}>
            <div className="muted" style={{ fontSize: '0.85rem' }}>الرصيد الحالي</div>
            <div style={{ fontSize: '1.8rem', fontWeight: 700, fontFamily: 'var(--mono)', color: (balance ?? 0) >= 0 ? 'var(--debit)' : 'var(--credit)' }}>
              {fmtMoney(Math.abs(balance ?? 0))}
            </div>
            <div className="muted" style={{ fontSize: '0.85rem' }}>{(balance ?? 0) >= 0 ? 'مدين' : 'دائن'}</div>
          </div>
        )}
      </div>

      {account.is_postable && (
        <>
          <h2>كشف الحساب</h2>
          <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
            <table>
              <thead>
                <tr><th style={{ width: 70 }}>#</th><th style={{ width: 110 }}>التاريخ</th><th>البيان</th><th className="num" style={{ width: 110 }}>مدين</th><th className="num" style={{ width: 110 }}>دائن</th><th className="num" style={{ width: 120 }}>الرصيد</th></tr>
              </thead>
              <tbody>
                {(!ledger || ledger.length === 0) && <tr><td colSpan={6} className="muted">لا حركات مرحّلة بعد.</td></tr>}
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
      )}
    </>
  );
}
