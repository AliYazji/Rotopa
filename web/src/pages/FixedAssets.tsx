import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Asset {
  id: string; code: string; name_ar: string; status: 'active' | 'disposed';
  cost: number; accumulated_depreciation: number; acquisition_date: string;
}
const STATUS: Record<string, string> = { active: 'نشط', disposed: 'مستبعد' };

export default function FixedAssets() {
  const { org } = useOrg();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [throughDate, setThroughDate] = useState(today());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);

  const { data, isLoading } = useQuery({
    queryKey: ['fixed-assets', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Asset[]> => {
      const { data, error } = await supabase
        .from('fixed_assets')
        .select('id, code, name_ar, status, cost, accumulated_depreciation, acquisition_date')
        .order('code');
      if (error) throw error;
      return data as Asset[];
    },
  });

  async function depreciateAll() {
    setErr(null); setResult(null); setBusy(true);
    try {
      const { data, error } = await supabase.rpc('depreciate_all_assets', { p_org: org!.id, p_through_date: throughDate });
      if (error) throw error;
      const rows = (data as { asset_id: string; journal_entry_id: string; amount: number }[]) ?? [];
      const total = rows.reduce((s, r) => s + Number(r.amount), 0);
      setResult(rows.length === 0 ? 'ما في أصل يستحق إهلاكاً حتى هذا التاريخ.' : `رُحّل إهلاك ${rows.length} أصل بإجمالي ${fmtMoney(total)}.`);
      await qc.invalidateQueries({ queryKey: ['fixed-assets'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>الأصول الثابتة</h1>
        <Link to="/fixed-assets/new" className="btn btn-primary">أصل جديد</Link>
      </div>

      <div className="card" style={{ maxWidth: 460, marginBottom: '1rem' }}>
        <h2 style={{ fontSize: '0.95rem' }}>ترحيل إهلاك دوري (كل الأصول النشطة)</h2>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <div className="field" style={{ width: 180 }}>
            <label>حتى تاريخ</label>
            <input type="date" value={throughDate} onChange={(e) => setThroughDate(e.target.value)} />
          </div>
          <button disabled={busy} onClick={depreciateAll}>ترحيل الإهلاك</button>
        </div>
        {result && <p className="muted" style={{ fontSize: '0.9rem' }}>{result}</p>}
        {err && <p className="error">{err}</p>}
      </div>

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 90 }}>الرمز</th>
              <th>الاسم</th>
              <th style={{ width: 110 }}>تاريخ الاقتناء</th>
              <th className="num" style={{ width: 110 }}>التكلفة</th>
              <th className="num" style={{ width: 110 }}>مجمع الإهلاك</th>
              <th className="num" style={{ width: 110 }}>صافي القيمة</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={7} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={7} className="muted">لا أصول ثابتة بعد.</td></tr>}
            {data?.map((a) => (
              <tr key={a.id} className="rowlink" onClick={() => nav(`/fixed-assets/${a.id}`)}>
                <td className="mono">{a.code}</td>
                <td>{a.name_ar}</td>
                <td>{fmtDate(a.acquisition_date)}</td>
                <td className="num">{fmtMoney(a.cost)}</td>
                <td className="num">{fmtMoney(a.accumulated_depreciation)}</td>
                <td className="num">{fmtMoney(a.cost - a.accumulated_depreciation)}</td>
                <td><span className={`badge ${a.status === 'active' ? 'posted' : 'void'}`}>{STATUS[a.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
