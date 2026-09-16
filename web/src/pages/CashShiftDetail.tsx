import { useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, fmtDate, translateError } from '../lib/format.ts';
import { AccountSelect, type AccOpt } from '../components/AccountSelect.tsx';
import { DenominationCounter, denominationsTotal, type Denominations } from '../components/DenominationCounter.tsx';

interface Shift {
  id: string; shift_no: number; status: 'open' | 'closed'; notes: string;
  opened_at: string; closed_at: string | null;
  opening_total: number; opening_denominations: Denominations; opening_gl_balance: number;
  closing_total: number | null; closing_denominations: Denominations | null; closing_gl_balance: number | null;
  expected_closing: number | null; variance: number | null;
  cash_account_id: string; cash_account: { code: string; name_ar: string } | null;
  cashier: { name_ar: string } | null;
  variance_journal_entry: { entry_no: number } | null;
}

const STATUS: Record<string, string> = { open: 'مفتوحة', closed: 'مغلقة' };

export default function CashShiftDetail() {
  const { id } = useParams();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [closingDenominations, setClosingDenominations] = useState<Denominations>({});
  const [varianceAccountId, setVarianceAccountId] = useState('');
  const [closeNotes, setCloseNotes] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: shift, isLoading } = useQuery({
    queryKey: ['cash-shift', id],
    enabled: !!id,
    queryFn: async (): Promise<Shift> => {
      const { data, error } = await supabase.from('cash_shifts')
        .select('id, shift_no, status, notes, opened_at, closed_at, opening_total, opening_denominations, opening_gl_balance, closing_total, closing_denominations, closing_gl_balance, expected_closing, variance, cash_account_id, cash_account:cash_account_id(code, name_ar), cashier:cashier_dealer_id(name_ar), variance_journal_entry:variance_journal_entry_id(entry_no)')
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as Shift;
    },
  });
  const { data: currentGlBalance } = useQuery({
    queryKey: ['cash-account-balance', shift?.cash_account_id],
    enabled: !!shift && shift.status === 'open',
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('account_balance', { p_account_id: shift!.cash_account_id });
      if (error) throw error;
      return Number(data ?? 0);
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts-grouped', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts')
        .select('id, code, name_ar, category_id, account_categories(name_ar)')
        .eq('is_postable', true).order('code');
      if (error) throw error; return data as unknown as AccOpt[];
    },
  });

  const closingTotal = denominationsTotal(closingDenominations);
  const expectedClosing = shift && currentGlBalance != null
    ? shift.opening_total + (currentGlBalance - shift.opening_gl_balance) : null;
  const previewVariance = expectedClosing != null ? closingTotal - expectedClosing : null;

  async function closeShift() {
    setErr(null); setBusy(true);
    try {
      if (previewVariance && Math.abs(previewVariance) > 0.0001 && !varianceAccountId) {
        throw new Error(`الجرد ما بيطابق المتوقّع (الفرق ${fmtMoney(Math.abs(previewVariance))}) — حدد حساب العجز أو الزيادة أولاً.`);
      }
      const { error } = await supabase.rpc('close_cash_shift', {
        p_shift_id: id, p_denominations: closingDenominations,
        p_variance_account_id: varianceAccountId || null, p_notes: closeNotes,
      });
      if (error) throw error;
      qc.invalidateQueries({ queryKey: ['cash-shift', id] });
      qc.invalidateQueries({ queryKey: ['cash-shifts', org?.id] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  if (isLoading || !shift) return <p className="muted">جارٍ التحميل…</p>;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>وردية رقم {shift.shift_no}</h1>
        <span className={`badge ${shift.status === 'open' ? 'draft' : 'posted'}`}>{STATUS[shift.status]}</span>
      </div>
      <p className="muted">
        {shift.cash_account?.code} · {shift.cash_account?.name_ar}
        {shift.cashier && <> · الكاشير: {shift.cashier.name_ar}</>}
      </p>

      <div className="row" style={{ alignItems: 'flex-start', gap: '1rem', flexWrap: 'wrap' }}>
        <div className="card" style={{ flex: '1 1 300px' }}>
          <h2 style={{ fontSize: '0.95rem' }}>جرد بداية الوردية</h2>
          <p className="muted" style={{ fontSize: '0.8rem' }}>{fmtDate(shift.opened_at)}</p>
          <table>
            <tbody>
              {Object.entries(shift.opening_denominations ?? {}).filter(([, c]) => Number(c) > 0).map(([d, c]) => (
                <tr key={d}><td className="mono">{d}</td><td className="num">{c}</td><td className="num mono">{fmtMoney(Number(d) * Number(c))}</td></tr>
              ))}
            </tbody>
            <tfoot><tr style={{ fontWeight: 700 }}><td colSpan={2}>الإجمالي</td><td className="num mono">{fmtMoney(shift.opening_total)}</td></tr></tfoot>
          </table>
          {shift.notes && <p className="muted" style={{ fontSize: '0.8rem', marginTop: '0.5rem' }}>{shift.notes}</p>}
        </div>

        {shift.status === 'closed' ? (
          <div className="card" style={{ flex: '1 1 300px' }}>
            <h2 style={{ fontSize: '0.95rem' }}>جرد نهاية الوردية</h2>
            <p className="muted" style={{ fontSize: '0.8rem' }}>{fmtDate(shift.closed_at)}</p>
            <table>
              <tbody>
                {Object.entries(shift.closing_denominations ?? {}).filter(([, c]) => Number(c) > 0).map(([d, c]) => (
                  <tr key={d}><td className="mono">{d}</td><td className="num">{c}</td><td className="num mono">{fmtMoney(Number(d) * Number(c))}</td></tr>
                ))}
              </tbody>
              <tfoot><tr style={{ fontWeight: 700 }}><td colSpan={2}>الإجمالي المعدود</td><td className="num mono">{fmtMoney(shift.closing_total)}</td></tr></tfoot>
            </table>
            <div className="row" style={{ justifyContent: 'space-between', marginTop: '0.5rem' }}>
              <span className="muted">المتوقّع</span><span className="mono">{fmtMoney(shift.expected_closing)}</span>
            </div>
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}>
              <span>الفرق</span>
              <span className="mono" style={{ color: !shift.variance ? undefined : shift.variance > 0 ? 'var(--credit)' : 'var(--danger)' }}>
                {fmtMoney(shift.variance)}
              </span>
            </div>
            {shift.variance_journal_entry && (
              <p className="muted" style={{ fontSize: '0.8rem', marginTop: '0.5rem' }}>
                رُحّل الفرق بقيد رقم {shift.variance_journal_entry.entry_no}.
              </p>
            )}
          </div>
        ) : (
          <div className="card" style={{ flex: '1 1 300px' }}>
            <h2 style={{ fontSize: '0.95rem' }}>إغلاق الوردية</h2>
            <DenominationCounter value={closingDenominations} onChange={setClosingDenominations} />
            <div className="row" style={{ justifyContent: 'space-between', marginTop: '0.5rem', fontSize: '0.85rem' }}>
              <span className="muted">المتوقّع حالياً</span>
              <span className="mono">{expectedClosing != null ? fmtMoney(expectedClosing) : '…'}</span>
            </div>
            {previewVariance != null && Math.abs(previewVariance) > 0.0001 && (
              <>
                <div className="row" style={{ justifyContent: 'space-between', fontSize: '0.85rem', fontWeight: 700 }}>
                  <span>الفرق المتوقّع</span>
                  <span className="mono" style={{ color: previewVariance > 0 ? 'var(--credit)' : 'var(--danger)' }}>{fmtMoney(previewVariance)}</span>
                </div>
                <div className="field" style={{ marginTop: '0.5rem' }}>
                  <label>{previewVariance > 0 ? 'حساب زيادة الصندوق' : 'حساب عجز الصندوق'}</label>
                  <AccountSelect accounts={accounts} value={varianceAccountId} placeholder="—" onChange={setVarianceAccountId} />
                </div>
              </>
            )}
            <div className="field" style={{ marginTop: '0.5rem' }}>
              <label>ملاحظات (اختياري)</label>
              <input value={closeNotes} onChange={(e) => setCloseNotes(e.target.value)} />
            </div>
            {err && <p className="error">{err}</p>}
            <button className="btn-primary" disabled={busy} onClick={closeShift} style={{ marginTop: '0.5rem' }}>إغلاق الوردية</button>
          </div>
        )}
      </div>

      <p style={{ marginTop: '1rem' }}><Link to="/cash-shifts">‹ رجوع لقائمة الورديات</Link></p>
    </>
  );
}
