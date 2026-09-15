import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';
import { ItemPicker } from '../components/ItemPicker.tsx';

interface WhOpt { id: string; code: string; name_ar: string; }
interface BomPreviewRow { component_item_id: string; qty: number; component: { code: string; name_ar: string; base_unit_name: string } | null; }

export default function ManufacturingOrderNew() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [date, setDate] = useState(today());
  const [finishedItemId, setFinishedItemId] = useState('');
  const [finishedItemLabel, setFinishedItemLabel] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [qty, setQty] = useState('1');
  const [desc, setDesc] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id], enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as WhOpt[];
    },
  });

  const { data: bomPreview } = useQuery({
    queryKey: ['bom-preview', finishedItemId],
    enabled: !!finishedItemId,
    queryFn: async (): Promise<BomPreviewRow[]> => {
      const { data, error } = await supabase.from('bom_lines')
        .select('component_item_id, qty, component:component_item_id(code, name_ar, base_unit_name)')
        .eq('finished_item_id', finishedItemId);
      if (error) throw error;
      return data as unknown as BomPreviewRow[];
    },
  });

  const qtyNum = parseFloat(qty) || 0;

  async function create() {
    setErr(null); setBusy(true);
    try {
      if (!finishedItemId) throw new Error('اختر الصنف المطلوب تصنيعه');
      if (!warehouseId) throw new Error('اختر المستودع');
      if (!(qtyNum > 0)) throw new Error('الكمية لازم تكون أكبر من صفر');
      if (!bomPreview || bomPreview.length === 0) {
        throw new Error('هذا الصنف بلا وصفة تصنيع (BOM) — أضِف مكوّناته أولاً من صفحة الصنف');
      }
      const { data: newId, error } = await supabase.rpc('create_manufacturing_order', {
        p_org: org!.id, p_order_date: date, p_finished_item_id: finishedItemId,
        p_warehouse_id: warehouseId, p_qty: qtyNum, p_description: desc,
      });
      if (error) throw error;
      nav(`/manufacturing-orders/${newId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>أمر تصنيع جديد</h1>
      <div className="card" style={{ maxWidth: 560 }}>
        <div className="row">
          <div className="field" style={{ width: 160 }}>
            <label>التاريخ</label>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="field grow">
            <label>المستودع</label>
            <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
              <option value="">—</option>
              {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
            </select>
          </div>
        </div>
        <div className="field">
          <label>الصنف المطلوب تصنيعه</label>
          <ItemPicker initialLabel={finishedItemLabel} onPick={(it) => { setFinishedItemId(it.id); setFinishedItemLabel(`${it.code} · ${it.name_ar}`); }} />
        </div>
        <div className="field" style={{ width: 140 }}>
          <label>الكمية المطلوب إنتاجها</label>
          <input className="num" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} />
        </div>
        <div className="field">
          <label>البيان (اختياري)</label>
          <input value={desc} onChange={(e) => setDesc(e.target.value)} />
        </div>

        {finishedItemId && (
          <div style={{ marginTop: '0.5rem' }}>
            <label>المكوّنات التي ستُستهلَك (حسب وصفة الصنف)</label>
            {!bomPreview?.length ? (
              <p className="error" style={{ margin: 0 }}>هذا الصنف بلا وصفة تصنيع — أضِف مكوّناته أولاً من صفحته.</p>
            ) : (
              <table>
                <thead><tr><th>المكوّن</th><th className="num" style={{ width: 140 }}>الكمية اللازمة</th></tr></thead>
                <tbody>
                  {bomPreview.map((b) => (
                    <tr key={b.component_item_id}>
                      <td>{b.component?.code} · {b.component?.name_ar}</td>
                      <td className="num">{fmtMoney(b.qty * qtyNum)} {b.component?.base_unit_name}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={create} style={{ marginTop: '1rem' }}>إنشاء المسودة</button>
      </div>
    </>
  );
}
