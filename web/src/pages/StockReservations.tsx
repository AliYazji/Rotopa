import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, translateError } from '../lib/format.ts';
import { ItemPicker } from '../components/ItemPicker.tsx';

interface Reservation {
  id: string; qty: number; status: 'active' | 'released' | 'fulfilled';
  source_type: string; notes: string; created_at: string; release_reason: string | null;
  item: { code: string; name_ar: string; base_unit_name: string } | null;
  warehouse: { code: string; name_ar: string } | null;
}
interface WhOpt { id: string; code: string; name_ar: string; }

const STATUS: Record<string, string> = { active: 'فعّال', released: 'مُلغى', fulfilled: 'منفَّذ' };

export default function StockReservations() {
  const { org } = useOrg();
  const qc = useQueryClient();

  const [itemId, setItemId] = useState('');
  const [itemLabel, setItemLabel] = useState('');
  const [baseUnitName, setBaseUnitName] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [qty, setQty] = useState('');
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionErr, setActionErr] = useState<string | null>(null);

  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id], enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as WhOpt[];
    },
  });

  const { data: available } = useQuery({
    queryKey: ['available-to-promise', itemId, warehouseId],
    enabled: !!itemId && !!warehouseId,
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('item_available_to_promise', { p_item_id: itemId, p_warehouse_id: warehouseId });
      if (error) throw error;
      return Number(data ?? 0);
    },
  });

  const { data: reservations, isLoading } = useQuery({
    queryKey: ['stock-reservations', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Reservation[]> => {
      const { data, error } = await supabase.from('stock_reservations')
        .select('id, qty, status, source_type, notes, created_at, release_reason, item:item_id(code, name_ar, base_unit_name), warehouse:warehouse_id(code, name_ar)')
        .order('created_at', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Reservation[];
    },
  });

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['stock-reservations', org?.id] });
    await qc.invalidateQueries({ queryKey: ['available-to-promise'] });
  }

  async function submit() {
    setErr(null);
    const qtyNum = parseFloat(qty);
    if (!itemId) return setErr('اختر الصنف');
    if (!warehouseId) return setErr('اختر المستودع');
    if (!(qtyNum > 0)) return setErr('الكمية لازم تكون أكبر من صفر');
    setBusy(true);
    try {
      const { error } = await supabase.rpc('reserve_stock', {
        p_org: org!.id, p_item_id: itemId, p_warehouse_id: warehouseId, p_qty: qtyNum, p_notes: notes || '',
      });
      if (error) throw error;
      setItemId(''); setItemLabel(''); setQty(''); setNotes('');
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function release(id: string) {
    setActionErr(null);
    const reason = window.prompt('سبب الإلغاء (اختياري):') ?? undefined;
    const { error } = await supabase.rpc('release_stock_reservation', { p_reservation_id: id, p_reason: reason || null });
    if (error) return setActionErr(translateError(error.message));
    await refresh();
  }
  async function fulfill(id: string) {
    setActionErr(null);
    const { error } = await supabase.rpc('fulfill_stock_reservation', { p_reservation_id: id });
    if (error) return setActionErr(translateError(error.message));
    await refresh();
  }

  return (
    <>
      <h1>حجز المخزون</h1>
      <p className="muted">
        الحجز بيقلّل "المتاح للوعد" فقط — ما بيحرّك المخزون الفعلي ولا بيرحّل أي قيد. البيع الفعلي
        (فاتورة/كاشير) لسا بيتحقق من الرصيد الفعلي بالمستودع، مش من الحجوزات.
      </p>

      <div className="card" style={{ maxWidth: 640, marginBottom: '1.5rem' }}>
        <div className="row">
          <div className="field grow">
            <label>الصنف</label>
            <ItemPicker
              initialLabel={itemLabel} warehouseId={warehouseId || undefined}
              onPick={(it) => { setItemId(it.id); setItemLabel(`${it.code} · ${it.name_ar}`); setBaseUnitName(it.base_unit_name); }}
            />
          </div>
          <div className="field" style={{ width: 180 }}>
            <label>المستودع</label>
            <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
              <option value="">—</option>
              {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
            </select>
          </div>
        </div>
        {itemId && warehouseId && (
          <p className="muted" style={{ fontSize: '0.85rem' }}>المتاح للوعد حالياً: <strong>{fmtMoney(available ?? 0)} {baseUnitName}</strong></p>
        )}
        <div className="row">
          <div className="field" style={{ width: 140 }}>
            <label>الكمية</label>
            <input className="num" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} />
          </div>
          <div className="field grow">
            <label>ملاحظات (اختياري)</label>
            <input value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>
        </div>
        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={submit}>احجز</button>
      </div>

      {actionErr && <p className="error">{actionErr}</p>}
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th>الصنف</th>
              <th style={{ width: 110 }}>المستودع</th>
              <th className="num" style={{ width: 90 }}>الكمية</th>
              <th>ملاحظات</th>
              <th style={{ width: 100 }}>التاريخ</th>
              <th style={{ width: 90 }}>الحالة</th>
              <th style={{ width: 160 }} />
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={7} className="muted">جارٍ التحميل…</td></tr>}
            {reservations?.length === 0 && <tr><td colSpan={7} className="muted">لا حجوزات بعد.</td></tr>}
            {reservations?.map((r) => (
              <tr key={r.id}>
                <td>{r.item?.code} · {r.item?.name_ar}</td>
                <td>{r.warehouse?.code} · {r.warehouse?.name_ar}</td>
                <td className="num">{fmtMoney(r.qty)} {r.item?.base_unit_name}</td>
                <td className="muted">{r.notes || (r.release_reason ? `أُلغي: ${r.release_reason}` : '—')}</td>
                <td>{fmtDate(r.created_at)}</td>
                <td><span className={`badge ${r.status === 'fulfilled' ? 'posted' : r.status === 'released' ? 'void' : ''}`}>{STATUS[r.status]}</span></td>
                <td>
                  {r.status === 'active' && (
                    <div className="row" style={{ gap: '0.4rem' }}>
                      <button onClick={() => fulfill(r.id)}>تنفيذ</button>
                      <button className="btn-danger" onClick={() => release(r.id)}>إلغاء</button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
