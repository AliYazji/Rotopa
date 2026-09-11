import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Asset {
  id: string; code: string; name_ar: string; status: 'active' | 'disposed';
  asset_account_id: string; accum_depreciation_account_id: string; depreciation_expense_account_id: string;
  acquisition_date: string; cost: number; salvage_value: number; useful_life_months: number;
  accumulated_depreciation: number; last_depreciated_through: string | null; notes: string;
  disposal_date: string | null; disposal_proceeds: number | null; disposal_reason: string | null;
  acquisition_journal_entry_id: string | null; disposal_journal_entry_id: string | null;
  asset_account: { code: string; name_ar: string } | null;
  accum_depreciation_account: { code: string; name_ar: string } | null;
  depreciation_expense_account: { code: string; name_ar: string } | null;
}
interface Run { id: string; through_date: string; amount: number; journal_entry_id: string | null; }
interface AccOpt { id: string; code: string; name_ar: string; }

const STATUS: Record<string, string> = { active: 'نشط', disposed: 'مستبعد' };

export default function FixedAssetDetail() {
  const { id } = useParams();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [nameAr, setNameAr] = useState('');
  const [notes, setNotes] = useState('');
  const [depExpAccountId, setDepExpAccountId] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [depThrough, setDepThrough] = useState(today());
  const [dispDate, setDispDate] = useState(today());
  const [dispProceeds, setDispProceeds] = useState('0');
  const [dispProceedsAccountId, setDispProceedsAccountId] = useState('');
  const [dispGainLossAccountId, setDispGainLossAccountId] = useState('');
  const [dispReason, setDispReason] = useState('');

  const { data: asset, isLoading } = useQuery({
    queryKey: ['fixed-asset', id],
    enabled: !!id,
    queryFn: async (): Promise<Asset> => {
      const { data, error } = await supabase.from('fixed_assets')
        .select(`id, code, name_ar, status, asset_account_id, accum_depreciation_account_id, depreciation_expense_account_id,
                  acquisition_date, cost, salvage_value, useful_life_months, accumulated_depreciation, last_depreciated_through,
                  notes, disposal_date, disposal_proceeds, disposal_reason, acquisition_journal_entry_id, disposal_journal_entry_id,
                  asset_account:asset_account_id(code, name_ar),
                  accum_depreciation_account:accum_depreciation_account_id(code, name_ar),
                  depreciation_expense_account:depreciation_expense_account_id(code, name_ar)`)
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as Asset;
    },
  });
  const { data: runs } = useQuery({
    queryKey: ['fixed-asset-runs', id],
    enabled: !!id,
    queryFn: async (): Promise<Run[]> => {
      const { data, error } = await supabase.from('fixed_asset_depreciation_runs')
        .select('id, through_date, amount, journal_entry_id').eq('asset_id', id).order('through_date');
      if (error) throw error;
      return data as Run[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  useEffect(() => {
    if (asset) { setNameAr(asset.name_ar); setNotes(asset.notes ?? ''); setDepExpAccountId(asset.depreciation_expense_account_id); }
  }, [asset]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['fixed-asset', id] });
    await qc.invalidateQueries({ queryKey: ['fixed-asset-runs', id] });
    await qc.invalidateQueries({ queryKey: ['fixed-assets'] });
  }

  async function saveCosmetic() {
    setErr(null); setBusy(true);
    try {
      const { error } = await supabase.from('fixed_assets')
        .update({ name_ar: nameAr, notes, depreciation_expense_account_id: depExpAccountId }).eq('id', id);
      if (error) throw error;
      setEditing(false);
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function runDepreciation() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_depreciation', { p_asset_id: id, p_through_date: depThrough });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function dispose() {
    setErr(null); setBusy(true);
    const proceeds = parseFloat(dispProceeds) || 0;
    const { error } = await supabase.rpc('dispose_fixed_asset', {
      p_asset_id: id, p_disposal_date: dispDate, p_proceeds: proceeds,
      p_proceeds_account_id: proceeds > 0 ? dispProceedsAccountId || null : null,
      p_gain_loss_account_id: dispGainLossAccountId || null,
      p_reason: dispReason || null,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  if (isLoading || !asset) return <p className="muted">جارٍ التحميل…</p>;
  const monthly = (asset.cost - asset.salvage_value) / asset.useful_life_months;
  const nbv = asset.cost - asset.accumulated_depreciation;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{asset.name_ar} <span className="mono muted" style={{ fontSize: '1rem' }}>{asset.code}</span></h1>
        <span className={`badge ${asset.status === 'active' ? 'posted' : 'void'}`}>{STATUS[asset.status]}</span>
      </div>

      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap', marginBottom: '1.25rem' }}>
        <div className="card" style={{ flex: '1 1 360px' }}>
          {!editing ? (
            <>
              <table>
                <tbody>
                  <tr><td className="muted">حساب الأصل</td><td>{asset.asset_account?.code} · {asset.asset_account?.name_ar}</td></tr>
                  <tr><td className="muted">حساب مجمع الإهلاك</td><td>{asset.accum_depreciation_account?.code} · {asset.accum_depreciation_account?.name_ar}</td></tr>
                  <tr><td className="muted">حساب مصروف الإهلاك</td><td>{asset.depreciation_expense_account?.code} · {asset.depreciation_expense_account?.name_ar}</td></tr>
                  <tr><td className="muted">تاريخ الاقتناء</td><td>{fmtDate(asset.acquisition_date)}</td></tr>
                  <tr><td className="muted">التكلفة</td><td className="num">{fmtMoney(asset.cost)}</td></tr>
                  <tr><td className="muted">قيمة الخردة</td><td className="num">{fmtMoney(asset.salvage_value)}</td></tr>
                  <tr><td className="muted">العمر الإنتاجي</td><td>{asset.useful_life_months} شهر</td></tr>
                  <tr><td className="muted">إهلاك شهري</td><td className="num">{fmtMoney(monthly)}</td></tr>
                  <tr><td className="muted">مجمع الإهلاك</td><td className="num">{fmtMoney(asset.accumulated_depreciation)}</td></tr>
                  <tr><td className="muted">صافي القيمة الدفترية</td><td className="num" style={{ fontWeight: 700 }}>{fmtMoney(nbv)}</td></tr>
                  <tr><td className="muted">آخر إهلاك حتى</td><td>{asset.last_depreciated_through ? fmtDate(asset.last_depreciated_through) : '—'}</td></tr>
                  <tr><td className="muted">ملاحظات</td><td>{asset.notes || '—'}</td></tr>
                  {asset.acquisition_journal_entry_id && (
                    <tr><td className="muted">قيد التسجيل</td><td><Link to={`/journals/${asset.acquisition_journal_entry_id}`}>عرض القيد ›</Link></td></tr>
                  )}
                </tbody>
              </table>
              <button onClick={() => setEditing(true)} style={{ marginTop: '0.75rem' }}>تعديل البيانات الوصفية</button>
            </>
          ) : (
            <>
              <div className="field"><label>الاسم</label><input value={nameAr} onChange={(e) => setNameAr(e.target.value)} /></div>
              <div className="field">
                <label>حساب مصروف الإهلاك</label>
                <select value={depExpAccountId} onChange={(e) => setDepExpAccountId(e.target.value)}>
                  {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                </select>
              </div>
              <div className="field"><label>ملاحظات</label><input value={notes} onChange={(e) => setNotes(e.target.value)} /></div>
              <p className="muted" style={{ fontSize: '0.85rem' }}>التكلفة وتاريخ الاقتناء والحسابات الأساسية ثابتة ولا تتغيّر بعد التسجيل — للتصحيح استبعد الأصل وسجّل نسخة صحيحة.</p>
              {err && <p className="error">{err}</p>}
              <div className="row">
                <button className="btn-primary" disabled={busy} onClick={saveCosmetic}>حفظ</button>
                <button disabled={busy} onClick={() => { setEditing(false); setErr(null); setNameAr(asset.name_ar); setNotes(asset.notes ?? ''); setDepExpAccountId(asset.depreciation_expense_account_id); }}>إلغاء</button>
              </div>
            </>
          )}
        </div>

        {asset.status === 'active' && (
          <div className="card" style={{ flex: '1 1 300px' }}>
            <h2 style={{ fontSize: '0.95rem' }}>ترحيل إهلاك</h2>
            <div className="field"><label>حتى تاريخ</label><input type="date" value={depThrough} onChange={(e) => setDepThrough(e.target.value)} /></div>
            {err && <p className="error">{err}</p>}
            <button className="btn-primary" disabled={busy} onClick={runDepreciation}>ترحيل الإهلاك</button>

            <h2 style={{ fontSize: '0.95rem', marginTop: '1.5rem' }}>استبعاد الأصل</h2>
            <div className="field"><label>تاريخ الاستبعاد</label><input type="date" value={dispDate} onChange={(e) => setDispDate(e.target.value)} /></div>
            <div className="field"><label>عائد البيع (0 إن لم يوجد)</label><input className="num" inputMode="decimal" value={dispProceeds} onChange={(e) => setDispProceeds(e.target.value)} /></div>
            {parseFloat(dispProceeds) > 0 && (
              <div className="field">
                <label>حساب استلام العائد</label>
                <select value={dispProceedsAccountId} onChange={(e) => setDispProceedsAccountId(e.target.value)}>
                  <option value="">—</option>
                  {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                </select>
              </div>
            )}
            <div className="field">
              <label>حساب أرباح/خسائر الاستبعاد (لازم لو العائد مختلف عن صافي القيمة الدفترية)</label>
              <select value={dispGainLossAccountId} onChange={(e) => setDispGainLossAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
            <div className="field"><label>السبب (اختياري)</label><input value={dispReason} onChange={(e) => setDispReason(e.target.value)} /></div>
            <button className="btn-danger" disabled={busy} onClick={dispose}>استبعاد الأصل</button>
          </div>
        )}

        {asset.status === 'disposed' && (
          <div className="card" style={{ flex: '1 1 300px' }}>
            <h2 style={{ fontSize: '0.95rem' }}>الاستبعاد</h2>
            <table>
              <tbody>
                <tr><td className="muted">التاريخ</td><td>{fmtDate(asset.disposal_date)}</td></tr>
                <tr><td className="muted">العائد</td><td className="num">{fmtMoney(asset.disposal_proceeds)}</td></tr>
                {asset.disposal_reason && <tr><td className="muted">السبب</td><td>{asset.disposal_reason}</td></tr>}
                {asset.disposal_journal_entry_id && (
                  <tr><td className="muted">القيد</td><td><Link to={`/journals/${asset.disposal_journal_entry_id}`}>عرض القيد ›</Link></td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <h2>سجل الإهلاك</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
        <table>
          <thead><tr><th>حتى تاريخ</th><th className="num" style={{ width: 130 }}>المبلغ</th><th style={{ width: 100 }}>القيد</th></tr></thead>
          <tbody>
            {(!runs || runs.length === 0) && <tr><td colSpan={3} className="muted">لا إهلاك مُرحّل بعد.</td></tr>}
            {runs?.map((r) => (
              <tr key={r.id}>
                <td>{fmtDate(r.through_date)}</td>
                <td className="num">{fmtMoney(r.amount)}</td>
                <td>{r.journal_entry_id && <Link to={`/journals/${r.journal_entry_id}`}>عرض ›</Link>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p style={{ marginTop: '1rem' }}><Link to="/fixed-assets">‹ رجوع لقائمة الأصول الثابتة</Link></p>
    </>
  );
}
