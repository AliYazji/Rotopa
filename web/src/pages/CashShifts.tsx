import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, fmtDate, translateError } from '../lib/format.ts';
import { DenominationCounter, type Denominations } from '../components/DenominationCounter.tsx';

interface AccOpt { id: string; code: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; }
interface Shift {
  id: string; shift_no: number; status: 'open' | 'closed'; opened_at: string; closed_at: string | null;
  opening_total: number; closing_total: number | null; variance: number | null;
  cash_account: { code: string; name_ar: string } | null;
  cashier: { name_ar: string } | null;
}

const STATUS: Record<string, string> = { open: 'مفتوحة', closed: 'مغلقة' };

export default function CashShifts() {
  const { org, posRegisterIds } = useOrg();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [newOpen, setNewOpen] = useState(false);
  const [cashAccountId, setCashAccountId] = useState('');
  const [cashierDealerId, setCashierDealerId] = useState('');
  const [notes, setNotes] = useState('');
  const [denominations, setDenominations] = useState<Denominations>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: shifts, isLoading } = useQuery({
    queryKey: ['cash-shifts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Shift[]> => {
      const { data, error } = await supabase.from('cash_shifts')
        .select('id, shift_no, status, opened_at, closed_at, opening_total, closing_total, variance, cash_account:cash_account_id(code, name_ar), cashier:cashier_dealer_id(name_ar)')
        .order('shift_no', { ascending: false });
      if (error) throw error;
      return data as unknown as Shift[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });
  // Settings > صناديق الكاشير curates this the same way it does in the
  // POS Cashier itself — an empty curated list means "not set up yet"
  const cashRegisterOptions = posRegisterIds.length === 0 ? accounts : accounts?.filter((a) => posRegisterIds.includes(a.id));
  const { data: employees } = useQuery({
    queryKey: ['employee-dealers', org?.id], enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').eq('is_employee', true).order('name_ar');
      if (error) throw error; return data as DealerOpt[];
    },
  });

  async function openShift() {
    setErr(null);
    if (!cashAccountId) return setErr('اختر الصندوق');
    setBusy(true);
    try {
      const { data: shiftId, error } = await supabase.rpc('open_cash_shift', {
        p_org: org!.id, p_cash_account_id: cashAccountId, p_denominations: denominations,
        p_cashier_dealer_id: cashierDealerId || null, p_notes: notes,
      });
      if (error) throw error;
      qc.invalidateQueries({ queryKey: ['cash-shifts', org?.id] });
      nav(`/cash-shifts/${shiftId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>ورديات الصندوق</h1>
      {err && <p className="error">{err}</p>}

      {!newOpen ? (
        <button onClick={() => setNewOpen(true)} style={{ marginBottom: '0.75rem' }}>+ فتح وردية جديدة</button>
      ) : (
        <div className="card" style={{ marginBottom: '1rem', maxWidth: 480 }}>
          <h2 style={{ fontSize: '0.95rem' }}>فتح وردية</h2>
          <div className="field">
            <label>الصندوق</label>
            <select value={cashAccountId} onChange={(e) => setCashAccountId(e.target.value)}>
              <option value="">—</option>
              {cashRegisterOptions?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
          <div className="field">
            <label>الكاشير (اختياري)</label>
            <select value={cashierDealerId} onChange={(e) => setCashierDealerId(e.target.value)}>
              <option value="">—</option>
              {employees?.map((d) => <option key={d.id} value={d.id}>{d.name_ar}</option>)}
            </select>
          </div>
          <div className="field">
            <label>جرد بداية الوردية</label>
            <DenominationCounter value={denominations} onChange={setDenominations} />
          </div>
          <div className="field">
            <label>ملاحظات (اختياري)</label>
            <input value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>
          <div className="row" style={{ marginTop: '0.5rem' }}>
            <button className="btn-primary" disabled={busy || !cashAccountId} onClick={openShift}>فتح الوردية</button>
            <button disabled={busy} onClick={() => { setNewOpen(false); setCashAccountId(''); setCashierDealerId(''); setDenominations({}); setNotes(''); }}>إلغاء</button>
          </div>
        </div>
      )}

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th>رقم</th><th>الصندوق</th><th>الكاشير</th><th>الحالة</th>
              <th>وقت الفتح</th><th>وقت الإغلاق</th>
              <th className="num">الافتتاحي</th><th className="num">الختامي</th><th className="num">الفرق</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={9} className="muted">جارٍ التحميل…</td></tr>}
            {shifts?.map((s) => (
              <tr key={s.id} className="rowlink" onClick={() => nav(`/cash-shifts/${s.id}`)}>
                <td className="mono">{s.shift_no}</td>
                <td>{s.cash_account?.code} · {s.cash_account?.name_ar}</td>
                <td className="muted">{s.cashier?.name_ar ?? '—'}</td>
                <td><span className={`badge ${s.status === 'open' ? 'draft' : 'posted'}`}>{STATUS[s.status]}</span></td>
                <td className="muted">{fmtDate(s.opened_at)}</td>
                <td className="muted">{s.closed_at ? fmtDate(s.closed_at) : '—'}</td>
                <td className="num mono">{fmtMoney(s.opening_total)}</td>
                <td className="num mono">{s.closing_total != null ? fmtMoney(s.closing_total) : '—'}</td>
                <td className="num mono" style={{ color: !s.variance ? undefined : s.variance > 0 ? 'var(--credit)' : 'var(--danger)' }}>
                  {s.variance != null ? fmtMoney(s.variance) : '—'}
                </td>
              </tr>
            ))}
            {shifts && shifts.length === 0 && <tr><td colSpan={9} className="muted">ما في ورديات بعد.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
