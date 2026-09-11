import { Fragment, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today } from '../lib/format.ts';

interface Cheque {
  id: string;
  direction: 'incoming' | 'outgoing';
  cheque_no: string;
  cheque_date: string;
  amount: number;
  status: 'in_hand' | 'deposited' | 'cleared' | 'bounced' | 'cancelled' | 'endorsed';
  dealer: { name_ar: string } | null;
  bank_name: string | null;
}
interface AccOpt { id: string; code: string; name_ar: string; }

const STATUS: Record<string, string> = {
  in_hand: 'في الحافظة', deposited: 'تحت التحصيل', cleared: 'محصّل',
  bounced: 'مرتد', cancelled: 'ملغى', endorsed: 'مجيّر',
};
const DIR: Record<string, string> = { incoming: 'وارد', outgoing: 'صادر' };

export default function Cheques() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [expanded, setExpanded] = useState<string | null>(null);

  const { data, isLoading } = useQuery({
    queryKey: ['cheques', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Cheque[]> => {
      const { data, error } = await supabase
        .from('cheques')
        .select('id, direction, cheque_no, cheque_date, amount, status, bank_name, dealer:dealer_id(name_ar)')
        .order('cheque_date', { ascending: false });
      if (error) throw error;
      return data as unknown as Cheque[];
    },
  });

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar')
        .eq('is_postable', true).eq('allow_transactions', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  const refresh = () => qc.invalidateQueries({ queryKey: ['cheques', org?.id] });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>الشيكات</h1>
        <div className="row">
          <Link to="/cheques/new?direction=incoming" className="btn btn-primary">شيك وارد</Link>
          <Link to="/cheques/new?direction=outgoing" className="btn">شيك صادر</Link>
        </div>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 100 }}>الرقم</th>
              <th style={{ width: 60 }}>الاتجاه</th>
              <th>الطرف</th>
              <th style={{ width: 110 }}>الاستحقاق</th>
              <th className="num" style={{ width: 110 }}>المبلغ</th>
              <th style={{ width: 100 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={6} className="muted">لا شيكات بعد.</td></tr>}
            {data?.map((c) => (
              <Fragment key={c.id}>
                <tr onClick={() => setExpanded(expanded === c.id ? null : c.id)} style={{ cursor: 'pointer' }}>
                  <td className="mono">{c.cheque_no}</td>
                  <td>{DIR[c.direction]}</td>
                  <td>{c.dealer?.name_ar}</td>
                  <td>{fmtDate(c.cheque_date)}</td>
                  <td className="num">{fmtMoney(c.amount)}</td>
                  <td><span className={`badge ${c.status === 'cleared' ? 'posted' : c.status === 'bounced' ? 'void' : ''}`}>{STATUS[c.status]}</span></td>
                </tr>
                {expanded === c.id && (
                  <tr>
                    <td colSpan={6} style={{ background: 'var(--surface-2)' }}>
                      <ChequeActions cheque={c} accounts={accounts ?? []} onDone={refresh} />
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

function ChequeActions({ cheque, accounts, onDone }: { cheque: Cheque; accounts: AccOpt[]; onDone: () => void }) {
  const [bankAccountId, setBankAccountId] = useState('');
  const [targetAccountId, setTargetAccountId] = useState('');
  const [date, setDate] = useState(today());
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function run(fn: () => PromiseLike<{ error: any }>) {
    setErr(null);
    setBusy(true);
    const { error } = await fn();
    setBusy(false);
    if (error) return setErr(error.message);
    onDone();
  }

  if (cheque.status === 'in_hand') {
    return (
      <div className="row" style={{ flexWrap: 'wrap', gap: '0.75rem', padding: '0.75rem 0' }}>
        <select value={bankAccountId} onChange={(e) => setBankAccountId(e.target.value)} style={{ width: 220 }}>
          <option value="">اختر حساب البنك…</option>
          {accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
        </select>
        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} style={{ width: 150 }} />
        <button disabled={busy || !bankAccountId} onClick={() => run(() => supabase.rpc('set_cheque_deposited', { p_cheque_id: cheque.id, p_bank_account_id: bankAccountId }))}>
          إيداع بالبنك
        </button>
        <button className="btn-primary" disabled={busy || !bankAccountId} onClick={() => run(() => supabase.rpc('clear_cheque', { p_cheque_id: cheque.id, p_date: date, p_bank_account_id: bankAccountId }))}>
          تحصيل مباشر
        </button>
        <input placeholder="سبب الإلغاء" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: 160 }} />
        <button className="btn-danger" disabled={busy} onClick={() => run(() => supabase.rpc('cancel_cheque', { p_cheque_id: cheque.id, p_date: date, p_reason: reason || null }))}>
          إلغاء الشيك
        </button>
        {cheque.direction === 'incoming' && (
          <>
            <select value={targetAccountId} onChange={(e) => setTargetAccountId(e.target.value)} style={{ width: 220 }}>
              <option value="">حساب التجيير إليه…</option>
              {accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
            <button disabled={busy || !targetAccountId} onClick={() => run(() => supabase.rpc('endorse_cheque', { p_cheque_id: cheque.id, p_date: date, p_target_account_id: targetAccountId, p_reason: reason || null }))}>
              تجيير
            </button>
          </>
        )}
        {err && <p className="error" style={{ width: '100%' }}>{err}</p>}
      </div>
    );
  }

  if (cheque.status === 'deposited') {
    return (
      <div className="row" style={{ flexWrap: 'wrap', gap: '0.75rem', padding: '0.75rem 0' }}>
        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} style={{ width: 150 }} />
        <button className="btn-primary" disabled={busy} onClick={() => run(() => supabase.rpc('clear_cheque', { p_cheque_id: cheque.id, p_date: date }))}>
          تحصيل
        </button>
        <input placeholder="سبب الارتداد" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: 160 }} />
        <button className="btn-danger" disabled={busy} onClick={() => run(() => supabase.rpc('bounce_cheque', { p_cheque_id: cheque.id, p_date: date, p_reason: reason || null }))}>
          ارتداد
        </button>
        {err && <p className="error" style={{ width: '100%' }}>{err}</p>}
      </div>
    );
  }

  return <p className="muted" style={{ padding: '0.75rem 0' }}>شيك {STATUS[cheque.status]} — لا إجراء إضافي متاح.</p>;
}
