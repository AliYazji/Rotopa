import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney, translateError } from '../lib/format.ts';
import { ItemPicker } from '../components/ItemPicker.tsx';

interface Order {
  id: string; order_no: number; order_date: string; qty: number; description: string;
  status: 'draft' | 'posted' | 'void'; void_reason: string | null;
  labor_cost: number; equipment_cost: number; subcontractor_cost: number; other_cost: number;
  finished_item_id: string; warehouse_id: string;
  finished_item: { code: string; name_ar: string; base_unit_name: string } | null;
  warehouse: { name_ar: string } | null;
}
interface Line {
  id: string; line_no: number; component_item_id: string; qty: number; unit_cost: number | null;
  component: { code: string; name_ar: string; base_unit_name: string } | null;
}
interface AccOpt { id: string; code: string; name_ar: string; }

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function ManufacturingOrderDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState('');

  const [labor, setLabor] = useState('0');
  const [equipment, setEquipment] = useState('0');
  const [subcontractor, setSubcontractor] = useState('0');
  const [other, setOther] = useState('0');
  const [laborAcc, setLaborAcc] = useState('');
  const [equipAcc, setEquipAcc] = useState('');
  const [subAcc, setSubAcc] = useState('');
  const [otherAcc, setOtherAcc] = useState('');

  const [newComponentId, setNewComponentId] = useState('');
  const [newComponentLabel, setNewComponentLabel] = useState('');
  const [newComponentQty, setNewComponentQty] = useState('');

  const { data: order, isLoading } = useQuery({
    queryKey: ['manufacturing-order', id],
    enabled: !!id,
    queryFn: async (): Promise<Order> => {
      const { data, error } = await supabase.from('manufacturing_orders')
        .select('id, order_no, order_date, qty, description, status, void_reason, labor_cost, equipment_cost, subcontractor_cost, other_cost, finished_item_id, warehouse_id, finished_item:finished_item_id(code, name_ar, base_unit_name), warehouse:warehouse_id(name_ar)')
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as Order;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['manufacturing-order-lines', id],
    enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('manufacturing_order_lines')
        .select('id, line_no, component_item_id, qty, unit_cost, component:component_item_id(code, name_ar, base_unit_name)')
        .eq('order_id', id).order('line_no');
      if (error) throw error;
      return data as unknown as Line[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts-mfg'],
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  useEffect(() => {
    if (order) {
      setLabor(String(order.labor_cost)); setEquipment(String(order.equipment_cost));
      setSubcontractor(String(order.subcontractor_cost)); setOther(String(order.other_cost));
    }
  }, [order]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['manufacturing-order', id] });
    await qc.invalidateQueries({ queryKey: ['manufacturing-order-lines', id] });
    await qc.invalidateQueries({ queryKey: ['manufacturing-orders'] });
  }

  async function saveCosts() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('manufacturing_orders').update({
      labor_cost: parseFloat(labor) || 0, equipment_cost: parseFloat(equipment) || 0,
      subcontractor_cost: parseFloat(subcontractor) || 0, other_cost: parseFloat(other) || 0,
    }).eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function addLine() {
    setErr(null);
    const qty = parseFloat(newComponentQty);
    if (!newComponentId || !(qty > 0) || !lines) return;
    setBusy(true);
    const { error } = await supabase.from('manufacturing_order_lines').insert({
      order_id: id, line_no: (lines.at(-1)?.line_no ?? 0) + 1, component_item_id: newComponentId, qty,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setNewComponentId(''); setNewComponentLabel(''); setNewComponentQty('');
    await refresh();
  }
  async function removeLine(lineId: string) {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('manufacturing_order_lines').delete().eq('id', lineId);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function updateLineQty(lineId: string, qty: number) {
    setErr(null);
    const { error } = await supabase.from('manufacturing_order_lines').update({ qty }).eq('id', lineId);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function post() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_manufacturing_order', {
      p_order_id: id,
      p_labor_account_id: parseFloat(labor) > 0 ? (laborAcc || null) : null,
      p_equipment_account_id: parseFloat(equipment) > 0 ? (equipAcc || null) : null,
      p_subcontractor_account_id: parseFloat(subcontractor) > 0 ? (subAcc || null) : null,
      p_other_account_id: parseFloat(other) > 0 ? (otherAcc || null) : null,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('manufacturing_orders').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/manufacturing-orders');
  }
  async function voidOrder() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('void_manufacturing_order', { p_order_id: id, p_date: order!.order_date, p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  if (isLoading || !order) return <p className="muted">جارٍ التحميل…</p>;

  const materialCost = lines?.reduce((s, l) => s + Number(l.qty) * Number(l.unit_cost ?? 0), 0) ?? 0;
  const overheadCost = (parseFloat(labor) || 0) + (parseFloat(equipment) || 0) + (parseFloat(subcontractor) || 0) + (parseFloat(other) || 0);
  const unitCost = order.status === 'posted' && order.qty > 0 ? (materialCost + overheadCost) / order.qty : null;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>أمر تصنيع رقم {order.order_no}</h1>
        <span className={`badge ${order.status}`}>{STATUS[order.status]}</span>
      </div>
      <p className="muted">
        {fmtDate(order.order_date)} · {order.finished_item?.code} · {order.finished_item?.name_ar} ·
        {' '}{fmtMoney(order.qty)} {order.finished_item?.base_unit_name} · مستودع {order.warehouse?.name_ar}
      </p>
      {err && <p className="error">{err}</p>}

      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
        <table>
          <thead>
            <tr><th>المكوّن</th><th className="num" style={{ width: 120 }}>الكمية</th>{order.status !== 'draft' && <th className="num" style={{ width: 120 }}>تكلفة الوحدة</th>}<th style={{ width: 40 }} /></tr>
          </thead>
          <tbody>
            {lines?.map((l) => (
              <tr key={l.id}>
                <td>{l.component?.code} · {l.component?.name_ar}</td>
                <td className="num">
                  {order.status === 'draft' ? (
                    <input className="num" inputMode="decimal" defaultValue={l.qty} onBlur={(e) => { const v = parseFloat(e.target.value); if (v > 0 && v !== l.qty) updateLineQty(l.id, v); }} />
                  ) : (
                    <>{fmtMoney(l.qty)} {l.component?.base_unit_name}</>
                  )}
                </td>
                {order.status !== 'draft' && <td className="num">{l.unit_cost != null ? fmtMoney(l.unit_cost) : '—'}</td>}
                <td>{order.status === 'draft' && <button type="button" onClick={() => removeLine(l.id)}>×</button>}</td>
              </tr>
            ))}
            {order.status === 'draft' && (
              <tr>
                <td><ItemPicker initialLabel={newComponentLabel} onPick={(it) => { setNewComponentId(it.id); setNewComponentLabel(`${it.code} · ${it.name_ar}`); }} /></td>
                <td><input className="num" inputMode="decimal" value={newComponentQty} onChange={(e) => setNewComponentQty(e.target.value)} placeholder="0" /></td>
                <td><button type="button" className="btn-primary" onClick={addLine}>+</button></td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {order.status === 'draft' && (
        <div className="card" style={{ maxWidth: 480, marginBottom: '1rem' }}>
          <h2 style={{ fontSize: '0.95rem' }}>تكاليف التشغيل الإضافية</h2>
          <div className="row">
            <div className="field grow"><label>عمالة</label><input className="num" inputMode="decimal" value={labor} onChange={(e) => setLabor(e.target.value)} /></div>
            <div className="field grow"><label>معدات</label><input className="num" inputMode="decimal" value={equipment} onChange={(e) => setEquipment(e.target.value)} /></div>
          </div>
          <div className="row">
            <div className="field grow"><label>مقاولون</label><input className="num" inputMode="decimal" value={subcontractor} onChange={(e) => setSubcontractor(e.target.value)} /></div>
            <div className="field grow"><label>أخرى</label><input className="num" inputMode="decimal" value={other} onChange={(e) => setOther(e.target.value)} /></div>
          </div>
          <button disabled={busy} onClick={saveCosts}>حفظ التكاليف</button>
        </div>
      )}

      {order.status === 'draft' && (
        <div className="card" style={{ maxWidth: 480 }}>
          <h2 style={{ fontSize: '0.95rem' }}>ترحيل أمر التصنيع</h2>
          <p className="muted" style={{ fontSize: '0.85rem' }}>
            تكلفة المواد: {fmtMoney(materialCost)} + تكاليف التشغيل: {fmtMoney(overheadCost)} = {fmtMoney(materialCost + overheadCost)} إجمالي،
            {' '}أي {fmtMoney((materialCost + overheadCost) / (order.qty || 1))} لكل {order.finished_item?.base_unit_name}
          </p>
          {parseFloat(labor) > 0 && (
            <div className="field"><label>حساب العمالة</label>
              <select value={laborAcc} onChange={(e) => setLaborAcc(e.target.value)}><option value="">—</option>{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}</select>
            </div>
          )}
          {parseFloat(equipment) > 0 && (
            <div className="field"><label>حساب المعدات</label>
              <select value={equipAcc} onChange={(e) => setEquipAcc(e.target.value)}><option value="">—</option>{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}</select>
            </div>
          )}
          {parseFloat(subcontractor) > 0 && (
            <div className="field"><label>حساب المقاولين</label>
              <select value={subAcc} onChange={(e) => setSubAcc(e.target.value)}><option value="">—</option>{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}</select>
            </div>
          )}
          {parseFloat(other) > 0 && (
            <div className="field"><label>حساب التكاليف الأخرى</label>
              <select value={otherAcc} onChange={(e) => setOtherAcc(e.target.value)}><option value="">—</option>{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}</select>
            </div>
          )}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={post}>ترحيل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}

      {order.status === 'posted' && (
        <div className="card" style={{ maxWidth: 480 }}>
          <p className="muted" style={{ fontSize: '0.9rem', marginTop: 0 }}>
            تكلفة الوحدة الفعلية: <strong>{unitCost != null ? fmtMoney(unitCost) : '—'}</strong> (مواد + تشغيل)
          </p>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء أمر التصنيع</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>يعيد المكوّنات للمخزون ويسحب الصنف المُصنَّع.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          <button className="btn-danger" disabled={busy} onClick={voidOrder}>إلغاء</button>
        </div>
      )}
      {order.status === 'void' && (
        <p className="muted">أُلغي{order.void_reason ? ` — ${order.void_reason}` : ''}.</p>
      )}

      <p style={{ marginTop: '1rem' }}><Link to="/manufacturing-orders">‹ رجوع لأوامر التصنيع</Link></p>
    </>
  );
}
