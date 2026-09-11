import { useEffect, useMemo, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Voucher {
  id: string; voucher_no: number; voucher_date: string; voucher_type: 'receipt' | 'payment';
  status: 'draft' | 'posted' | 'void'; description: string; cash_account_id: string; void_reason: string | null;
  cash_account: { code: string; name_ar: string } | null;
}
interface Line {
  id: string; line_no: number; account_id: string; amount: number; description: string; dealer_id: string | null;
  account: { code: string; name_ar: string } | null; dealer: { name_ar: string } | null;
}
interface AccOpt { id: string; code: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; }
interface EditLine { key: number; accountId: string; amount: string; description: string; dealerId: string }
let keySeq = 0;
const toEditLine = (l: Line): EditLine => ({ key: keySeq++, accountId: l.account_id, amount: String(l.amount), description: l.description, dealerId: l.dealer_id ?? '' });

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function VoucherDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);
  const [desc, setDesc] = useState('');
  const [cashAccountId, setCashAccountId] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: voucher, isLoading } = useQuery({
    queryKey: ['voucher', id], enabled: !!id,
    queryFn: async (): Promise<Voucher> => {
      const { data, error } = await supabase.from('vouchers')
        .select('id, voucher_no, voucher_date, voucher_type, status, description, cash_account_id, void_reason, cash_account:cash_account_id(code, name_ar)')
        .eq('id', id).single();
      if (error) throw error; return data as unknown as Voucher;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['voucher-lines', id], enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('voucher_lines')
        .select('id, line_no, account_id, amount, description, dealer_id, account:account_id(code, name_ar), dealer:dealer_id(name_ar)')
        .eq('voucher_id', id).order('line_no');
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
  const { data: dealers } = useQuery({
    queryKey: ['dealers-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').order('name_ar');
      if (error) throw error; return data as DealerOpt[];
    },
  });

  useEffect(() => { if (voucher) { setDesc(voucher.description ?? ''); setCashAccountId(voucher.cash_account_id); } }, [voucher]);
  useEffect(() => { if (lines) setEditLines(lines.map(toEditLine)); }, [lines]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['voucher', id] });
    await qc.invalidateQueries({ queryKey: ['voucher-lines', id] });
    await qc.invalidateQueries({ queryKey: ['vouchers'] });
  }

  const editTotal = useMemo(() => editLines.reduce((s, l) => s + (parseFloat(l.amount) || 0), 0), [editLines]);

  function setEditLine(key: number, patch: Partial<EditLine>) {
    setEditLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function saveDraft() {
    setErr(null); setBusy(true);
    try {
      if (!cashAccountId) throw new Error('اختر حساب الصندوق/البنك');
      const valid = editLines.filter((l) => l.accountId && (parseFloat(l.amount) || 0) > 0);
      if (valid.length < 1) throw new Error('أضف سطراً واحداً على الأقل');

      const { error: uErr } = await supabase.from('vouchers').update({ description: desc, cash_account_id: cashAccountId }).eq('id', id);
      if (uErr) throw uErr;
      const { error: dErr } = await supabase.from('voucher_lines').delete().eq('voucher_id', id);
      if (dErr) throw dErr;
      const { error: iErr } = await supabase.from('voucher_lines').insert(
        valid.map((l, i) => ({
          voucher_id: id, line_no: i + 1, account_id: l.accountId,
          amount: parseFloat(l.amount) || 0, description: l.description, dealer_id: l.dealerId || null,
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
    const { error } = await supabase.rpc('post_voucher', { p_voucher_id: id });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('vouchers').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/vouchers');
  }
  async function voidVoucher() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('void_voucher', { p_voucher_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function duplicateToDraft() {
    setErr(null); setBusy(true);
    try {
      const { data: newId, error } = await supabase.rpc('create_voucher', {
        p_org: org!.id,
        p_voucher_type: voucher!.voucher_type,
        p_voucher_date: today(),
        p_description: voucher!.description ? `نسخة عن سند رقم ${voucher!.voucher_no} — ${voucher!.description}` : `نسخة عن سند رقم ${voucher!.voucher_no}`,
        p_cash_account_id: voucher!.cash_account_id,
        p_currency_id: org!.base_currency_id,
        p_lines: (lines ?? []).map((l) => ({ account_id: l.account_id, amount: l.amount, description: l.description, dealer_id: l.dealer_id })),
        p_rate: 1,
        p_method: 'cash',
      });
      if (error) throw error;
      nav(`/vouchers/${newId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  if (isLoading || !voucher) return <p className="muted">جارٍ التحميل…</p>;
  const isReceipt = voucher.voucher_type === 'receipt';
  const total = editing ? editTotal : (lines?.reduce((s, l) => s + Number(l.amount), 0) ?? 0);

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{isReceipt ? 'سند قبض' : 'سند صرف'} رقم {voucher.voucher_no}</h1>
        <span className={`badge ${voucher.status}`}>{STATUS[voucher.status]}</span>
      </div>
      <p className="muted">{fmtDate(voucher.voucher_date)} · حساب {isReceipt ? 'الإيداع' : 'السحب'}: {voucher.cash_account?.code} · {voucher.cash_account?.name_ar}</p>

      {voucher.status === 'draft' && editing ? (
        <div className="card">
          <div className="row">
            <div className="field grow">
              <label>حساب {isReceipt ? 'الإيداع (الصندوق/البنك)' : 'السحب (الصندوق/البنك)'}</label>
              <select value={cashAccountId} onChange={(e) => setCashAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          </div>
          <div className="field"><label>البيان</label><input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>
          <table style={{ marginTop: '0.5rem' }}>
            <thead>
              <tr>
                <th>{isReceipt ? 'من حساب' : 'إلى حساب'}</th>
                <th style={{ width: 150 }} className="num">المبلغ</th>
                <th style={{ width: 160 }}>الطرف (اختياري)</th>
                <th>بيان السطر</th>
                <th style={{ width: 40 }} />
              </tr>
            </thead>
            <tbody>
              {editLines.map((l) => (
                <tr key={l.key}>
                  <td>
                    <select value={l.accountId} onChange={(e) => setEditLine(l.key, { accountId: e.target.value })}>
                      <option value="">—</option>
                      {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                    </select>
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.amount} onChange={(e) => setEditLine(l.key, { amount: e.target.value })} /></td>
                  <td>
                    <select value={l.dealerId} onChange={(e) => setEditLine(l.key, { dealerId: e.target.value })}>
                      <option value="">—</option>
                      {dealers?.map((d) => <option key={d.id} value={d.id}>{d.name_ar}</option>)}
                    </select>
                  </td>
                  <td><input value={l.description} onChange={(e) => setEditLine(l.key, { description: e.target.value })} /></td>
                  <td>{editLines.length > 1 && <button type="button" onClick={() => setEditLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td>الإجمالي</td><td className="num">{fmtMoney(editTotal)}</td><td colSpan={3} />
              </tr>
            </tfoot>
          </table>
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, accountId: '', amount: '', description: '', dealerId: '' }])} style={{ marginTop: '0.5rem' }}>+ سطر</button>
          {err && <p className="error">{err}</p>}
          <div className="row" style={{ marginTop: '1rem' }}>
            <button className="btn-primary" disabled={busy} onClick={saveDraft}>حفظ التعديلات</button>
            <button disabled={busy} onClick={() => { setEditing(false); setErr(null); if (lines) setEditLines(lines.map(toEditLine)); }}>إلغاء</button>
          </div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
          <table>
            <thead><tr><th>{isReceipt ? 'من حساب' : 'إلى حساب'}</th><th className="num" style={{ width: 130 }}>المبلغ</th><th>الطرف</th><th>بيان السطر</th></tr></thead>
            <tbody>
              {lines?.map((l) => (
                <tr key={l.id}>
                  <td className="mono">{l.account?.code} · {l.account?.name_ar}</td>
                  <td className="num">{fmtMoney(l.amount)}</td>
                  <td>{l.dealer?.name_ar ?? ''}</td>
                  <td>{l.description}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr style={{ fontWeight: 700 }}><td>الإجمالي</td><td className="num">{fmtMoney(total)}</td><td colSpan={2} /></tr></tfoot>
          </table>
        </div>
      )}

      {voucher.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 420 }}>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postDraft}>ترحيل</button>
            <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}
      {voucher.status === 'posted' && (
        <div className="card" style={{ maxWidth: 420 }}>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء السند</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>بينشئ سنداً وقيداً عكسياً — السند الأصلي بيضل موجود وثابت.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-danger" disabled={busy} onClick={voidVoucher}>إلغاء السند</button>
            <button disabled={busy} onClick={duplicateToDraft}>نسخ لمسودة جديدة</button>
          </div>
        </div>
      )}
      {voucher.status === 'void' && (
        <div className="card" style={{ maxWidth: 420 }}>
          <p className="muted">أُلغي{voucher.void_reason ? ` — ${voucher.void_reason}` : ''}.</p>
          {err && <p className="error">{err}</p>}
          <button disabled={busy} onClick={duplicateToDraft}>نسخ لمسودة جديدة</button>
        </div>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/vouchers">‹ رجوع لقائمة السندات</Link></p>
    </>
  );
}
