import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface Outlet { id: string; code: string; name_ar: string; }
interface TableOpt { id: string; outlet_id: string; table_no: string; status: string; }
interface WhOpt { id: string; code: string; name_ar: string; }

export default function PosOrderNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [outletId, setOutletId] = useState('');
  const [tableId, setTableId] = useState('');
  const [isTakeaway, setIsTakeaway] = useState(false);
  const [warehouseId, setWarehouseId] = useState('');
  const [guestCount, setGuestCount] = useState('');
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: outlets } = useQuery({
    queryKey: ['outlets', org?.id], enabled: !!org,
    queryFn: async (): Promise<Outlet[]> => {
      const { data, error } = await supabase.from('outlets').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as Outlet[];
    },
  });
  const { data: tables } = useQuery({
    queryKey: ['free-tables', org?.id, outletId], enabled: !!org && !!outletId,
    queryFn: async (): Promise<TableOpt[]> => {
      const { data, error } = await supabase.from('pos_tables').select('id, outlet_id, table_no, status')
        .eq('outlet_id', outletId).eq('is_active', true).eq('status', 'free').order('table_no');
      if (error) throw error; return data as TableOpt[];
    },
  });
  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id], enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as WhOpt[];
    },
  });

  async function save() {
    setErr(null); setBusy(true);
    try {
      if (!outletId) throw new Error('اختر المنفذ');
      if (!isTakeaway && !tableId) throw new Error('اختر طاولة، أو فعّل "سفري"');
      if (!warehouseId) throw new Error('اختر المستودع');

      const { data: id, error } = await supabase.rpc('open_pos_order', {
        p_org: org!.id, p_outlet_id: outletId, p_warehouse_id: warehouseId,
        p_table_id: isTakeaway ? null : tableId, p_guest_count: guestCount ? parseInt(guestCount, 10) : null,
        p_notes: notes,
      });
      if (error) throw error;
      nav(`/pos-orders/${id}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>طلب جديد</h1>
      <div className="card" style={{ maxWidth: 480 }}>
        <div className="field">
          <label>المنفذ</label>
          <select value={outletId} onChange={(e) => { setOutletId(e.target.value); setTableId(''); }}>
            <option value="">—</option>
            {outlets?.map((o) => <option key={o.id} value={o.id}>{o.code} · {o.name_ar}</option>)}
          </select>
        </div>
        <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', margin: '0.5rem 0' }}>
          <input type="checkbox" style={{ width: 'auto' }} checked={isTakeaway} onChange={(e) => setIsTakeaway(e.target.checked)} /> طلب سفري (بلا طاولة)
        </label>
        {!isTakeaway && (
          <div className="field">
            <label>الطاولة (المتاحة فقط)</label>
            <select value={tableId} onChange={(e) => setTableId(e.target.value)}>
              <option value="">—</option>
              {tables?.map((t) => <option key={t.id} value={t.id}>{t.table_no}</option>)}
            </select>
            {outletId && tables?.length === 0 && <p className="muted" style={{ fontSize: '0.85rem' }}>ما في طاولة متاحة بهذا المنفذ حالياً.</p>}
          </div>
        )}
        <div className="row">
          <div className="field grow">
            <label>المستودع</label>
            <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
              <option value="">—</option>
              {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
            </select>
          </div>
          <div className="field" style={{ width: 120 }}>
            <label>عدد الضيوف</label>
            <input className="num" inputMode="numeric" value={guestCount} onChange={(e) => setGuestCount(e.target.value)} />
          </div>
        </div>
        <div className="field"><label>ملاحظات</label><input value={notes} onChange={(e) => setNotes(e.target.value)} /></div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>فتح الطلب</button>
      </div>
    </>
  );
}
