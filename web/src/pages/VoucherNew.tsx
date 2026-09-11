import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today } from '../lib/format.ts';

interface AccOpt { id: string; code: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; }
interface Line { account_id: string; amount: string; description: string; dealer_id: string; }

const emptyLine = (): Line => ({ account_id: '', amount: '', description: '', dealer_id: '' });

export default function VoucherNew() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const type = params.get('type') === 'payment' ? 'payment' : 'receipt';

  const [date, setDate] = useState(today());
  const [desc, setDesc] = useState('');
  const [cashAccountId, setCashAccountId] = useState('');
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase
        .from('accounts').select('id, code, name_ar')
        .eq('is_postable', true).eq('allow_transactions', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  const { data: dealers } = useQuery({
    queryKey: ['dealers-lite', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').order('name_ar');
      if (error) throw error;
      return data as DealerOpt[];
    },
  });

  const total = useMemo(() => lines.reduce((s, l) => s + (parseFloat(l.amount) || 0), 0), [lines]);

  function setLine(i: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  }

  async function save(thenPost: boolean) {
    setErr(null);
    setBusy(true);
    try {
      if (!cashAccountId) throw new Error('اختر حساب الصندوق/البنك');
      const payload = lines
        .filter((l) => l.account_id && (parseFloat(l.amount) || 0) > 0)
        .map((l) => ({
          account_id: l.account_id,
          amount: parseFloat(l.amount) || 0,
          description: l.description,
          dealer_id: l.dealer_id || null,
        }));
      if (payload.length < 1) throw new Error('أضف سطراً واحداً على الأقل');

      const { data: voucherId, error } = await supabase.rpc('create_voucher', {
        p_org: org!.id,
        p_voucher_type: type,
        p_voucher_date: date,
        p_description: desc,
        p_cash_account_id: cashAccountId,
        p_currency_id: org!.base_currency_id,
        p_lines: payload,
        p_rate: 1,
        p_method: 'cash',
      });
      if (error) throw error;

      if (thenPost) {
        const { error: pErr } = await supabase.rpc('post_voucher', { p_voucher_id: voucherId });
        if (pErr) throw pErr;
      }
      nav('/vouchers');
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>{type === 'receipt' ? 'سند قبض جديد' : 'سند صرف جديد'}</h1>
      <div className="card">
        <div className="row">
          <div className="field" style={{ width: 180 }}>
            <label>التاريخ</label>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="field grow">
            <label>حساب {type === 'receipt' ? 'الإيداع (الصندوق/البنك)' : 'السحب (الصندوق/البنك)'}</label>
            <select value={cashAccountId} onChange={(e) => setCashAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
        </div>
        <div className="field">
          <label>البيان</label>
          <input value={desc} onChange={(e) => setDesc(e.target.value)} placeholder="وصف السند" />
        </div>

        <table style={{ marginTop: '0.5rem' }}>
          <thead>
            <tr>
              <th>{type === 'receipt' ? 'من حساب' : 'إلى حساب'}</th>
              <th style={{ width: 150 }} className="num">المبلغ</th>
              <th style={{ width: 160 }}>الطرف (اختياري)</th>
              <th>بيان السطر</th>
              <th style={{ width: 40 }} />
            </tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td>
                  <select value={l.account_id} onChange={(e) => setLine(i, { account_id: e.target.value })}>
                    <option value="">—</option>
                    {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                  </select>
                </td>
                <td><input className="num" inputMode="decimal" value={l.amount} onChange={(e) => setLine(i, { amount: e.target.value })} /></td>
                <td>
                  <select value={l.dealer_id} onChange={(e) => setLine(i, { dealer_id: e.target.value })}>
                    <option value="">—</option>
                    {dealers?.map((d) => <option key={d.id} value={d.id}>{d.name_ar}</option>)}
                  </select>
                </td>
                <td><input value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} /></td>
                <td>
                  {lines.length > 1 && (
                    <button type="button" onClick={() => setLines((ls) => ls.filter((_, idx) => idx !== i))}>×</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700 }}>
              <td>الإجمالي</td>
              <td className="num">{fmtMoney(total)}</td>
              <td colSpan={3} />
            </tr>
          </tfoot>
        </table>

        <button type="button" onClick={() => setLines((ls) => [...ls, emptyLine()])} style={{ marginTop: '0.5rem' }}>
          + سطر
        </button>

        {err && <p className="error">{err}</p>}

        <div className="row" style={{ marginTop: '1rem' }}>
          <button disabled={busy} onClick={() => save(false)}>حفظ مسودة</button>
          <button className="btn-primary" disabled={busy || total <= 0} onClick={() => save(true)}>
            حفظ وترحيل
          </button>
        </div>
      </div>
    </>
  );
}
