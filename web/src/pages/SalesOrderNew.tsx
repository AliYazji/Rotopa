import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';
import { ItemPicker, type ItemUnitOpt } from '../components/ItemPicker.tsx';

interface DealerOpt { id: string; code: string; name_ar: string; }
interface WhOpt { id: string; code: string; name_ar: string; }

interface Line {
  key: number; itemId: string; itemLabel: string; qty: string; unitPrice: string; discountPct: string;
  baseUnitName: string; unitId: string; units: ItemUnitOpt[];
}
let keySeq = 0;
const emptyLine = (): Line => ({
  key: keySeq++, itemId: '', itemLabel: '', qty: '1', unitPrice: '', discountPct: '0',
  baseUnitName: '', unitId: '', units: [],
});

export default function SalesOrderNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [date, setDate] = useState(today());
  const [dealerId, setDealerId] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [description, setDescription] = useState('');
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: customers } = useQuery({
    queryKey: ['customers-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').eq('is_customer', true).order('name_ar').limit(500);
      if (error) throw error; return data as DealerOpt[];
    },
  });
  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id], enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as WhOpt[];
    },
  });

  const total = useMemo(
    () => lines.reduce((s, l) => {
      const qty = parseFloat(l.qty) || 0, price = parseFloat(l.unitPrice) || 0, disc = parseFloat(l.discountPct) || 0;
      return s + qty * price * (1 - disc / 100);
    }, 0),
    [lines],
  );

  function setLine(key: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function save() {
    setErr(null); setBusy(true);
    try {
      if (!dealerId) throw new Error('اختر العميل');
      if (!warehouseId) throw new Error('اختر المستودع');
      const validLines = lines.filter((l) => l.itemId && (parseFloat(l.qty) || 0) > 0 && parseFloat(l.unitPrice) >= 0);
      if (validLines.length === 0) throw new Error('أضف صنفاً واحداً على الأقل');

      const { data: orderId, error } = await supabase.rpc('create_sales_order', {
        p_org: org!.id, p_order_date: date, p_dealer_id: dealerId, p_warehouse_id: warehouseId,
        p_lines: validLines.map((l) => ({
          item_id: l.itemId, qty: parseFloat(l.qty), unit_price: parseFloat(l.unitPrice),
          discount_pct: parseFloat(l.discountPct) || 0, unit_id: l.unitId || null,
        })),
        p_description: description,
      });
      if (error) throw error;
      nav(`/sales-orders/${orderId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>طلب بيع جديد</h1>
      <div className="card">
        <div className="row">
          <div className="field" style={{ width: 160 }}>
            <label>التاريخ</label>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="field grow">
            <label>العميل</label>
            <select value={dealerId} onChange={(e) => setDealerId(e.target.value)}>
              <option value="">—</option>
              {customers?.map((d) => <option key={d.id} value={d.id}>{d.name_ar}</option>)}
            </select>
          </div>
          <div className="field grow">
            <label>المستودع</label>
            <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
              <option value="">—</option>
              {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
            </select>
          </div>
        </div>

        <table style={{ marginTop: '0.5rem' }}>
          <thead>
            <tr>
              <th>الصنف</th>
              <th style={{ width: 90 }} className="num">الكمية</th>
              <th style={{ width: 110 }}>الوحدة</th>
              <th style={{ width: 100 }} className="num">السعر</th>
              <th style={{ width: 90 }} className="num">خصم %</th>
              <th style={{ width: 100 }} className="num">الإجمالي</th>
              <th style={{ width: 40 }} />
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => {
              const lineTotal = (parseFloat(l.qty) || 0) * (parseFloat(l.unitPrice) || 0) * (1 - (parseFloat(l.discountPct) || 0) / 100);
              return (
                <tr key={l.key}>
                  <td>
                    <ItemPicker
                      initialLabel={l.itemLabel} warehouseId={warehouseId || undefined}
                      onPick={(it) => {
                        const defaultUnit = it.units.find((u) => u.is_sales_default);
                        setLine(l.key, {
                          itemId: it.id, itemLabel: `${it.code} · ${it.name_ar}`,
                          unitPrice: l.unitPrice || String(it.sales_price),
                          baseUnitName: it.base_unit_name, units: it.units, unitId: defaultUnit?.id ?? '',
                        });
                      }}
                    />
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.qty} onChange={(e) => setLine(l.key, { qty: e.target.value })} /></td>
                  <td>
                    <select value={l.unitId} onChange={(e) => setLine(l.key, { unitId: e.target.value })} disabled={!l.itemId}>
                      <option value="">{l.baseUnitName || '—'}</option>
                      {l.units.map((u) => <option key={u.id} value={u.id}>{u.unit_name} (= {u.conversion_factor} {l.baseUnitName})</option>)}
                    </select>
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.unitPrice} onChange={(e) => setLine(l.key, { unitPrice: e.target.value })} /></td>
                  <td><input className="num" inputMode="decimal" value={l.discountPct} onChange={(e) => setLine(l.key, { discountPct: e.target.value })} /></td>
                  <td className="num">{fmtMoney(lineTotal)}</td>
                  <td>{lines.length > 1 && <button type="button" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700 }}><td colSpan={5}>الإجمالي</td><td className="num">{fmtMoney(total)}</td><td /></tr>
          </tfoot>
        </table>
        <button type="button" onClick={() => setLines((ls) => [...ls, emptyLine()])} style={{ marginTop: '0.5rem' }}>+ صنف</button>

        <div className="field"><label>البيان (اختياري)</label><input value={description} onChange={(e) => setDescription(e.target.value)} /></div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save} style={{ marginTop: '1rem' }}>حفظ الطلب</button>
      </div>
    </>
  );
}
