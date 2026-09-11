import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface Outlet { id: string; code: string; name_ar: string; is_active: boolean; }
interface Table { id: string; outlet_id: string; table_no: string; seats: number | null; status: string; outlet: { name_ar: string } | null; }

const TABLE_STATUS: Record<string, string> = { free: 'متاحة', occupied: 'مشغولة', reserved: 'محجوزة' };

export default function Outlets() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [outletCode, setOutletCode] = useState('');
  const [outletName, setOutletName] = useState('');

  const [tableOutletId, setTableOutletId] = useState('');
  const [tableNo, setTableNo] = useState('');
  const [tableSeats, setTableSeats] = useState('');

  const { data: outlets } = useQuery({
    queryKey: ['outlets', org?.id], enabled: !!org,
    queryFn: async (): Promise<Outlet[]> => {
      const { data, error } = await supabase.from('outlets').select('id, code, name_ar, is_active').order('code');
      if (error) throw error; return data as Outlet[];
    },
  });
  const { data: tables } = useQuery({
    queryKey: ['pos-tables', org?.id], enabled: !!org,
    queryFn: async (): Promise<Table[]> => {
      const { data, error } = await supabase.from('pos_tables').select('id, outlet_id, table_no, seats, status, outlet:outlet_id(name_ar)').order('table_no');
      if (error) throw error; return data as unknown as Table[];
    },
  });

  async function addOutlet() {
    setErr(null); setBusy(true);
    try {
      if (!outletCode.trim() || !outletName.trim()) throw new Error('أدخل رمز واسم المنفذ');
      const { error } = await supabase.from('outlets').insert({ org_id: org!.id, code: outletCode.trim(), name_ar: outletName.trim() });
      if (error) throw error;
      setOutletCode(''); setOutletName('');
      await qc.invalidateQueries({ queryKey: ['outlets'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function addTable() {
    setErr(null); setBusy(true);
    try {
      if (!tableOutletId) throw new Error('اختر المنفذ');
      if (!tableNo.trim()) throw new Error('أدخل رقم الطاولة');
      const { error } = await supabase.from('pos_tables').insert({
        org_id: org!.id, outlet_id: tableOutletId, table_no: tableNo.trim(), seats: tableSeats ? parseInt(tableSeats, 10) : null,
      });
      if (error) throw error;
      setTableNo(''); setTableSeats('');
      await qc.invalidateQueries({ queryKey: ['pos-tables'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>المنافذ والطاولات</h1>
      {err && <p className="error">{err}</p>}

      <h2 style={{ fontSize: '1rem' }}>المنافذ</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '0.75rem' }}>
        <table>
          <thead><tr><th style={{ width: 90 }}>الرمز</th><th>الاسم</th></tr></thead>
          <tbody>
            {outlets?.length === 0 && <tr><td colSpan={2} className="muted">لا منافذ بعد.</td></tr>}
            {outlets?.map((o) => <tr key={o.id}><td className="mono">{o.code}</td><td>{o.name_ar}</td></tr>)}
          </tbody>
        </table>
      </div>
      <div className="card" style={{ marginBottom: '1.5rem' }}>
        <div className="row">
          <div className="field" style={{ width: 110 }}><label>الرمز</label><input value={outletCode} onChange={(e) => setOutletCode(e.target.value)} /></div>
          <div className="field grow"><label>الاسم</label><input value={outletName} onChange={(e) => setOutletName(e.target.value)} /></div>
        </div>
        <button className="btn-primary" disabled={busy} onClick={addOutlet}>إضافة منفذ</button>
      </div>

      <h2 style={{ fontSize: '1rem' }}>الطاولات</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '0.75rem' }}>
        <table>
          <thead><tr><th style={{ width: 90 }}>الرقم</th><th>المنفذ</th><th style={{ width: 80 }}>المقاعد</th><th style={{ width: 100 }}>الحالة</th></tr></thead>
          <tbody>
            {tables?.length === 0 && <tr><td colSpan={4} className="muted">لا طاولات بعد.</td></tr>}
            {tables?.map((t) => (
              <tr key={t.id}>
                <td className="mono">{t.table_no}</td>
                <td>{t.outlet?.name_ar}</td>
                <td className="num">{t.seats ?? '—'}</td>
                <td><span className="badge">{TABLE_STATUS[t.status] ?? t.status}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="card">
        <div className="row">
          <div className="field grow">
            <label>المنفذ</label>
            <select value={tableOutletId} onChange={(e) => setTableOutletId(e.target.value)}>
              <option value="">—</option>
              {outlets?.map((o) => <option key={o.id} value={o.id}>{o.code} · {o.name_ar}</option>)}
            </select>
          </div>
          <div className="field" style={{ width: 120 }}><label>رقم الطاولة</label><input value={tableNo} onChange={(e) => setTableNo(e.target.value)} /></div>
          <div className="field" style={{ width: 100 }}><label>المقاعد (اختياري)</label><input className="num" inputMode="numeric" value={tableSeats} onChange={(e) => setTableSeats(e.target.value)} /></div>
        </div>
        <button className="btn-primary" disabled={busy} onClick={addTable}>إضافة طاولة</button>
      </div>
    </>
  );
}
