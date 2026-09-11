import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';

interface AccOpt { id: string; code: string; name_ar: string; }
interface Line { account_id: string; debit: string; credit: string; description: string; }

const emptyLine = (): Line => ({ account_id: '', debit: '', credit: '', description: '' });

export default function JournalNew() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [date, setDate] = useState(today());
  const [desc, setDesc] = useState('');
  const [lines, setLines] = useState<Line[]>([emptyLine(), emptyLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase
        .from('accounts')
        .select('id, code, name_ar')
        .eq('is_postable', true)
        .eq('allow_transactions', true)
        .order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  const totals = useMemo(() => {
    const d = lines.reduce((s, l) => s + (parseFloat(l.debit) || 0), 0);
    const c = lines.reduce((s, l) => s + (parseFloat(l.credit) || 0), 0);
    // Compare at cent precision — summing floats can leave d and c a
    // fraction of a cent apart even when every line is exact, so a raw
    // `d === c` falsely flags a balanced entry as unbalanced.
    return { d, c, balanced: Math.round(d * 100) === Math.round(c * 100) && d > 0 };
  }, [lines]);

  function setLine(i: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  }

  async function save(thenPost: boolean) {
    setErr(null);
    setBusy(true);
    try {
      const payload = lines
        .filter((l) => l.account_id && ((parseFloat(l.debit) || 0) > 0 || (parseFloat(l.credit) || 0) > 0))
        .map((l) => ({
          account_id: l.account_id,
          debit: parseFloat(l.debit) || 0,
          credit: parseFloat(l.credit) || 0,
          currency_id: org!.base_currency_id,
          rate: 1,
          description: l.description,
        }));
      if (payload.length < 2) throw new Error('القيد يحتاج سطرين على الأقل');

      const { data: entryId, error } = await supabase.rpc('create_journal_entry', {
        p_org: org!.id,
        p_entry_date: date,
        p_description: desc,
        p_lines: payload,
        p_document_currency_id: org!.base_currency_id,
      });
      if (error) throw error;

      if (thenPost) {
        const { error: pErr } = await supabase.rpc('post_journal_entry', { p_entry_id: entryId });
        if (pErr) throw pErr;
      }
      nav('/journals');
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>قيد جديد</h1>
      <div className="card">
        <div className="row">
          <div className="field" style={{ width: 180 }}>
            <label>التاريخ</label>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="field grow">
            <label>البيان</label>
            <input value={desc} onChange={(e) => setDesc(e.target.value)} placeholder="وصف القيد" />
          </div>
        </div>

        <table style={{ marginTop: '0.5rem' }}>
          <thead>
            <tr>
              <th>الحساب</th>
              <th style={{ width: 130 }} className="num">مدين</th>
              <th style={{ width: 130 }} className="num">دائن</th>
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
                    {accounts?.map((a) => (
                      <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>
                    ))}
                  </select>
                </td>
                <td>
                  <input
                    className="num" inputMode="decimal" value={l.debit}
                    onChange={(e) => setLine(i, { debit: e.target.value, credit: '' })}
                  />
                </td>
                <td>
                  <input
                    className="num" inputMode="decimal" value={l.credit}
                    onChange={(e) => setLine(i, { credit: e.target.value, debit: '' })}
                  />
                </td>
                <td><input value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} /></td>
                <td>
                  {lines.length > 2 && (
                    <button type="button" onClick={() => setLines((ls) => ls.filter((_, idx) => idx !== i))}>×</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700 }}>
              <td>الإجمالي</td>
              <td className="num">{fmtMoney(totals.d)}</td>
              <td className="num">{fmtMoney(totals.c)}</td>
              <td colSpan={2} className={totals.balanced ? '' : 'error'}>
                {totals.balanced ? 'متوازن ✓' : `الفرق ${fmtMoney(Math.abs(totals.d - totals.c))}`}
              </td>
            </tr>
          </tfoot>
        </table>

        <button type="button" onClick={() => setLines((ls) => [...ls, emptyLine()])} style={{ marginTop: '0.5rem' }}>
          + سطر
        </button>

        {err && <p className="error">{err}</p>}

        <div className="row" style={{ marginTop: '1rem' }}>
          <button disabled={busy} onClick={() => save(false)}>حفظ مسودة</button>
          <button className="btn-primary" disabled={busy || !totals.balanced} onClick={() => save(true)}>
            حفظ وترحيل
          </button>
        </div>
      </div>
    </>
  );
}
