import { useEffect, useMemo, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Entry {
  id: string; entry_no: number; entry_date: string; description: string;
  status: 'draft' | 'posted' | 'void'; source_type: string; void_reason: string | null;
}
interface Line {
  id: string; line_no: number; account_id: string; debit: number; credit: number; description: string;
  account: { code: string; name_ar: string } | null;
}
interface AccOpt { id: string; code: string; name_ar: string; }
interface EditLine { key: number; accountId: string; debit: string; credit: string; description: string }
let keySeq = 0;
const toEditLine = (l: Line): EditLine => ({ key: keySeq++, accountId: l.account_id, debit: l.debit ? String(l.debit) : '', credit: l.credit ? String(l.credit) : '', description: l.description });

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function JournalDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);
  const [desc, setDesc] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: entry, isLoading } = useQuery({
    queryKey: ['journal-entry', id], enabled: !!id,
    queryFn: async (): Promise<Entry> => {
      const { data, error } = await supabase.from('journal_entries')
        .select('id, entry_no, entry_date, description, status, source_type, void_reason').eq('id', id).single();
      if (error) throw error; return data as Entry;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['journal-entry-lines', id], enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('journal_lines')
        .select('id, line_no, account_id, debit, credit, description, account:account_id(code, name_ar)')
        .eq('entry_id', id).order('line_no');
      if (error) throw error; return data as unknown as Line[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar')
        .eq('is_postable', true).eq('allow_transactions', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  useEffect(() => { if (entry) setDesc(entry.description ?? ''); }, [entry]);
  useEffect(() => { if (lines) setEditLines(lines.map(toEditLine)); }, [lines]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['journal-entry', id] });
    await qc.invalidateQueries({ queryKey: ['journal-entry-lines', id] });
    await qc.invalidateQueries({ queryKey: ['journals'] });
  }

  const editTotals = useMemo(() => {
    const d = editLines.reduce((s, l) => s + (parseFloat(l.debit) || 0), 0);
    const c = editLines.reduce((s, l) => s + (parseFloat(l.credit) || 0), 0);
    // Compare at cent precision — see JournalNew.tsx for why raw d === c
    // false-flags a balanced entry due to float summation noise.
    return { d, c, balanced: Math.round(d * 100) === Math.round(c * 100) && d > 0 };
  }, [editLines]);

  function setEditLine(key: number, patch: Partial<EditLine>) {
    setEditLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function saveDraft() {
    setErr(null); setBusy(true);
    try {
      const valid = editLines.filter((l) => l.accountId && ((parseFloat(l.debit) || 0) > 0 || (parseFloat(l.credit) || 0) > 0));
      if (valid.length < 2) throw new Error('القيد يحتاج سطرين على الأقل');

      const { error: uErr } = await supabase.from('journal_entries').update({ description: desc }).eq('id', id);
      if (uErr) throw uErr;
      const { error: dErr } = await supabase.from('journal_lines').delete().eq('entry_id', id);
      if (dErr) throw dErr;
      const { error: iErr } = await supabase.from('journal_lines').insert(
        valid.map((l, i) => ({
          entry_id: id, line_no: i + 1, account_id: l.accountId,
          debit: parseFloat(l.debit) || 0, credit: parseFloat(l.credit) || 0,
          currency_id: org!.base_currency_id, rate: 1, description: l.description,
        })),
      );
      if (iErr) throw iErr;
      setEditing(false);
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function postDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_journal_entry', { p_entry_id: id });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('journal_entries').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/journals');
  }
  async function voidEntry() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('void_journal_entry', { p_entry_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  if (isLoading || !entry) return <p className="muted">جارٍ التحميل…</p>;
  const canWriteManually = entry.source_type === 'manual';
  const total = editing ? editTotals.d : (lines?.reduce((s, l) => s + Number(l.debit), 0) ?? 0);

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>قيد رقم {entry.entry_no}</h1>
        <span className={`badge ${entry.status}`}>{STATUS[entry.status]}</span>
      </div>
      <p className="muted">{fmtDate(entry.entry_date)}{entry.source_type !== 'manual' ? ` · المصدر: ${entry.source_type}` : ''}</p>

      {entry.status === 'draft' && editing ? (
        <div className="card">
          <div className="field"><label>البيان</label><input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>
          <table style={{ marginTop: '0.5rem' }}>
            <thead><tr><th>الحساب</th><th style={{ width: 130 }} className="num">مدين</th><th style={{ width: 130 }} className="num">دائن</th><th>بيان السطر</th><th style={{ width: 40 }} /></tr></thead>
            <tbody>
              {editLines.map((l) => (
                <tr key={l.key}>
                  <td>
                    <select value={l.accountId} onChange={(e) => setEditLine(l.key, { accountId: e.target.value })}>
                      <option value="">—</option>
                      {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                    </select>
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.debit} onChange={(e) => setEditLine(l.key, { debit: e.target.value, credit: '' })} /></td>
                  <td><input className="num" inputMode="decimal" value={l.credit} onChange={(e) => setEditLine(l.key, { credit: e.target.value, debit: '' })} /></td>
                  <td><input value={l.description} onChange={(e) => setEditLine(l.key, { description: e.target.value })} /></td>
                  <td>{editLines.length > 2 && <button type="button" onClick={() => setEditLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td>الإجمالي</td><td className="num">{fmtMoney(editTotals.d)}</td><td className="num">{fmtMoney(editTotals.c)}</td>
                <td colSpan={2} className={editTotals.balanced ? '' : 'error'}>{editTotals.balanced ? 'متوازن ✓' : `الفرق ${fmtMoney(Math.abs(editTotals.d - editTotals.c))}`}</td>
              </tr>
            </tfoot>
          </table>
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, accountId: '', debit: '', credit: '', description: '' }])} style={{ marginTop: '0.5rem' }}>+ سطر</button>
          {err && <p className="error">{err}</p>}
          <div className="row" style={{ marginTop: '1rem' }}>
            <button className="btn-primary" disabled={busy} onClick={saveDraft}>حفظ التعديلات</button>
            <button disabled={busy} onClick={() => { setEditing(false); setErr(null); if (lines) setEditLines(lines.map(toEditLine)); }}>إلغاء</button>
          </div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
          <table>
            <thead><tr><th>الحساب</th><th className="num" style={{ width: 130 }}>مدين</th><th className="num" style={{ width: 130 }}>دائن</th><th>بيان السطر</th></tr></thead>
            <tbody>
              {lines?.map((l) => (
                <tr key={l.id}>
                  <td className="mono">{l.account?.code}</td>
                  <td className="num">{l.debit ? fmtMoney(l.debit) : ''}</td>
                  <td className="num">{l.credit ? fmtMoney(l.credit) : ''}</td>
                  <td>{l.description || l.account?.name_ar}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr style={{ fontWeight: 700 }}><td>الإجمالي</td><td className="num" colSpan={2}>{fmtMoney(total)}</td><td /></tr></tfoot>
          </table>
        </div>
      )}

      {entry.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 420 }}>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postDraft}>ترحيل</button>
            {canWriteManually && <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>}
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}
      {entry.status === 'posted' && (
        <div className="card" style={{ maxWidth: 420 }}>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء القيد</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>بينشئ قيداً عكسياً — القيد الأصلي بيضل موجود وثابت.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <button className="btn-danger" disabled={busy} onClick={voidEntry}>إلغاء القيد</button>
        </div>
      )}
      {entry.status === 'void' && (
        <p className="muted">أُلغي{entry.void_reason ? ` — ${entry.void_reason}` : ''}.</p>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/journals">‹ رجوع لقائمة القيود</Link></p>
    </>
  );
}
