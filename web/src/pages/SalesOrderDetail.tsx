import { useEffect, useMemo, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, translateError } from '../lib/format.ts';
import { ItemPicker, type ItemUnitOpt } from '../components/ItemPicker.tsx';

interface Order {
  id: string; order_no: number; order_date: string; status: 'draft' | 'confirmed' | 'cancelled';
  description: string; cancel_reason: string | null; dealer_id: string; warehouse_id: string;
  dealer: { name_ar: string } | null;
}
interface Line {
  id: string; line_no: number; item_id: string; qty: number; unit_price: number; discount_pct: number; line_total: number;
  unit_id: string | null;
  item: { code: string; name_ar: string; base_unit_name: string; item_units: ItemUnitOpt[] } | null;
  unit: { unit_name: string } | null;
}
interface DealerOpt { id: string; code: string; name_ar: string; }
interface WhOpt { id: string; code: string; name_ar: string; }
interface InvoicedRow { item_id: string; qty: number; sales_invoices: { status: string; sales_order_id: string } }
interface OrderInvoice { id: string; invoice_no: number; status: string; invoice_date: string }

interface EditLine {
  key: number; itemId: string; itemLabel: string; qty: string; unitPrice: string; discountPct: string;
  baseUnitName: string; unitId: string; units: ItemUnitOpt[];
}
let keySeq = 0;
const toEditLine = (l: Line): EditLine => ({
  key: keySeq++, itemId: l.item_id, itemLabel: `${l.item?.code} · ${l.item?.name_ar}`,
  qty: String(l.qty), unitPrice: String(l.unit_price), discountPct: String(l.discount_pct),
  baseUnitName: l.item?.base_unit_name ?? '', unitId: l.unit_id ?? '', units: l.item?.item_units ?? [],
});

const STATUS: Record<string, string> = { draft: 'مسودة', confirmed: 'مؤكَّد', cancelled: 'ملغى' };

export default function SalesOrderDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState('');
  const [invoiceQtys, setInvoiceQtys] = useState<Record<string, string>>({});
  const [invoicePaymentMethod, setInvoicePaymentMethod] = useState<'credit' | 'cash'>('credit');
  const [invoiceCashAccountId, setInvoiceCashAccountId] = useState('');

  const [editing, setEditing] = useState(false);
  const [dealerId, setDealerId] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [description, setDescription] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: order, isLoading } = useQuery({
    queryKey: ['sales-order', id],
    enabled: !!id,
    queryFn: async (): Promise<Order> => {
      const { data, error } = await supabase.from('sales_orders')
        .select('id, order_no, order_date, status, description, cancel_reason, dealer_id, warehouse_id, dealer:dealer_id(name_ar)')
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as Order;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['sales-order-lines', id],
    enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('sales_order_lines')
        .select('id, line_no, item_id, qty, unit_price, discount_pct, line_total, unit_id, item:item_id(code, name_ar, base_unit_name, item_units(id, unit_name, conversion_factor, is_sales_default, is_purchase_default)), unit:unit_id(unit_name)')
        .eq('order_id', id).order('line_no');
      if (error) throw error;
      return data as unknown as Line[];
    },
  });
  const { data: invoicedRows } = useQuery({
    queryKey: ['sales-order-invoiced', id],
    enabled: !!id,
    queryFn: async (): Promise<InvoicedRow[]> => {
      const { data, error } = await supabase.from('sales_invoice_lines')
        .select('item_id, qty, sales_invoices!inner(status, sales_order_id)')
        .eq('sales_invoices.sales_order_id', id).neq('sales_invoices.status', 'void');
      if (error) throw error;
      return data as unknown as InvoicedRow[];
    },
  });
  const { data: orderInvoices } = useQuery({
    queryKey: ['sales-order-invoices', id],
    enabled: !!id,
    queryFn: async (): Promise<OrderInvoice[]> => {
      const { data, error } = await supabase.from('sales_invoices')
        .select('id, invoice_no, status, invoice_date').eq('sales_order_id', id).order('invoice_no');
      if (error) throw error;
      return data as OrderInvoice[];
    },
  });

  const { data: customers } = useQuery({
    queryKey: ['customers-lite', org?.id], enabled: !!org && editing,
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
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async () => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as { id: string; code: string; name_ar: string }[];
    },
  });

  useEffect(() => {
    if (order) { setDealerId(order.dealer_id); setWarehouseId(order.warehouse_id); setDescription(order.description ?? ''); }
  }, [order]);
  useEffect(() => { if (lines) setEditLines(lines.map(toEditLine)); }, [lines]);

  const remaining = useMemo(() => {
    const already = new Map<string, number>();
    for (const r of invoicedRows ?? []) already.set(r.item_id, (already.get(r.item_id) ?? 0) + Number(r.qty));
    const m = new Map<string, number>();
    for (const l of lines ?? []) m.set(l.item_id, Number(l.qty) - (already.get(l.item_id) ?? 0));
    return m;
  }, [lines, invoicedRows]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['sales-order', id] });
    await qc.invalidateQueries({ queryKey: ['sales-order-lines', id] });
    await qc.invalidateQueries({ queryKey: ['sales-order-invoiced', id] });
    await qc.invalidateQueries({ queryKey: ['sales-order-invoices', id] });
    await qc.invalidateQueries({ queryKey: ['sales-orders'] });
  }

  function setEditLine(key: number, patch: Partial<EditLine>) {
    setEditLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function saveDraft() {
    setErr(null); setBusy(true);
    try {
      if (!dealerId) throw new Error('اختر العميل');
      if (!warehouseId) throw new Error('اختر المستودع');
      const valid = editLines.filter((l) => l.itemId && (parseFloat(l.qty) || 0) > 0 && parseFloat(l.unitPrice) >= 0);
      if (valid.length === 0) throw new Error('أضف صنفاً واحداً على الأقل');

      const { error: uErr } = await supabase.from('sales_orders')
        .update({ dealer_id: dealerId, warehouse_id: warehouseId, description }).eq('id', id);
      if (uErr) throw uErr;

      const { error: dErr } = await supabase.from('sales_order_lines').delete().eq('order_id', id);
      if (dErr) throw dErr;
      const { error: iErr } = await supabase.from('sales_order_lines').insert(
        valid.map((l, i) => ({
          order_id: id, line_no: i + 1, item_id: l.itemId,
          qty: parseFloat(l.qty), unit_price: parseFloat(l.unitPrice), discount_pct: parseFloat(l.discountPct) || 0,
          unit_id: l.unitId || null,
        })),
      );
      if (iErr) throw iErr;

      setEditing(false);
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('sales_orders').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/sales-orders');
  }

  async function confirmOrder() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('confirm_sales_order', { p_order_id: id });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function cancelOrder() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('cancel_sales_order', { p_order_id: id, p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function createInvoice() {
    setErr(null);
    const rows = (lines ?? [])
      .map((l) => ({ item_id: l.item_id, qty: parseFloat(invoiceQtys[l.item_id] || '0') || 0 }))
      .filter((r) => r.qty > 0);
    if (rows.length === 0) return setErr('أدخل كمية للفوترة بصنف واحد على الأقل');
    for (const r of rows) {
      const max = remaining.get(r.item_id) ?? 0;
      if (r.qty > max) return setErr(`الكمية المطلوب فوترتها أكبر من المتبقي (${fmtMoney(max)})`);
    }
    if (invoicePaymentMethod === 'cash' && !invoiceCashAccountId) return setErr('اختر حساب الصندوق/البنك');
    setBusy(true);
    try {
      const { data: invoiceId, error } = await supabase.rpc('invoice_sales_order', {
        p_order_id: id, p_lines: rows,
        p_payment_method: invoicePaymentMethod, p_cash_account_id: invoicePaymentMethod === 'cash' ? invoiceCashAccountId : null,
      });
      if (error) throw error;
      nav(`/sales-invoices/${invoiceId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  if (isLoading || !order) return <p className="muted">جارٍ التحميل…</p>;
  const total = (lines ?? []).reduce((s, l) => s + Number(l.line_total), 0);
  const fullyInvoiced = (lines ?? []).length > 0 && (lines ?? []).every((l) => (remaining.get(l.item_id) ?? 0) <= 0.005);

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>طلب بيع رقم {order.order_no}</h1>
        <span className={`badge ${order.status === 'confirmed' ? 'posted' : order.status === 'cancelled' ? 'void' : ''}`}>{STATUS[order.status]}</span>
      </div>
      <p className="muted">
        {fmtDate(order.order_date)} · {order.dealer?.name_ar}
        {order.status === 'confirmed' && fullyInvoiced && ' · تم فوترته بالكامل'}
      </p>

      {order.status === 'draft' && editing ? (
        <div className="card">
          <div className="row">
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
                <th style={{ width: 40 }} />
              </tr>
            </thead>
            <tbody>
              {editLines.map((l) => (
                <tr key={l.key}>
                  <td>
                    <ItemPicker
                      initialLabel={l.itemLabel} warehouseId={warehouseId || undefined}
                      onPick={(it) => {
                        const defaultUnit = it.units.find((u) => u.is_sales_default);
                        setEditLine(l.key, {
                          itemId: it.id, itemLabel: `${it.code} · ${it.name_ar}`, unitPrice: l.unitPrice || String(it.sales_price),
                          baseUnitName: it.base_unit_name, units: it.units, unitId: defaultUnit?.id ?? '',
                        });
                      }}
                    />
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.qty} onChange={(e) => setEditLine(l.key, { qty: e.target.value })} /></td>
                  <td>
                    <select value={l.unitId} onChange={(e) => setEditLine(l.key, { unitId: e.target.value })} disabled={!l.itemId}>
                      <option value="">{l.baseUnitName || '—'}</option>
                      {l.units.map((u) => <option key={u.id} value={u.id}>{u.unit_name} (= {u.conversion_factor} {l.baseUnitName})</option>)}
                    </select>
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.unitPrice} onChange={(e) => setEditLine(l.key, { unitPrice: e.target.value })} /></td>
                  <td><input className="num" inputMode="decimal" value={l.discountPct} onChange={(e) => setEditLine(l.key, { discountPct: e.target.value })} /></td>
                  <td>{editLines.length > 1 && <button type="button" onClick={() => setEditLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, itemId: '', itemLabel: '', qty: '1', unitPrice: '', discountPct: '0', baseUnitName: '', unitId: '', units: [] }])} style={{ marginTop: '0.5rem' }}>+ صنف</button>
          <div className="field"><label>البيان</label><input value={description} onChange={(e) => setDescription(e.target.value)} /></div>

          {err && <p className="error">{err}</p>}
          <div className="row" style={{ marginTop: '1rem' }}>
            <button className="btn-primary" disabled={busy} onClick={saveDraft}>حفظ التعديلات</button>
            <button disabled={busy} onClick={() => { setEditing(false); setErr(null); if (lines) setEditLines(lines.map(toEditLine)); }}>إلغاء</button>
          </div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
          <table>
            <thead>
              <tr>
                <th>الصنف</th>
                <th className="num" style={{ width: 90 }}>الكمية</th>
                <th className="num" style={{ width: 100 }}>السعر</th>
                <th className="num" style={{ width: 80 }}>خصم %</th>
                <th className="num" style={{ width: 100 }}>الإجمالي</th>
                {order.status === 'confirmed' && <th className="num" style={{ width: 100 }}>المتبقي</th>}
              </tr>
            </thead>
            <tbody>
              {lines?.map((l) => (
                <tr key={l.id}>
                  <td>{l.item?.code} · {l.item?.name_ar}</td>
                  <td className="num">{fmtMoney(l.qty)} {l.unit?.unit_name ?? l.item?.base_unit_name}</td>
                  <td className="num">{fmtMoney(l.unit_price)}</td>
                  <td className="num">{l.discount_pct}</td>
                  <td className="num">{fmtMoney(l.line_total)}</td>
                  {order.status === 'confirmed' && (
                    <td className="num muted">{fmtMoney(remaining.get(l.item_id) ?? 0)} {l.unit?.unit_name ?? l.item?.base_unit_name}</td>
                  )}
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td colSpan={4}>الإجمالي</td><td className="num">{fmtMoney(total)}</td>
                {order.status === 'confirmed' && <td />}
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {order.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 460 }}>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={confirmOrder}>تأكيد الطلب</button>
            <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}

      {order.status === 'confirmed' && (
        <>
          {!fullyInvoiced && (
            <div className="card" style={{ marginBottom: '1rem' }}>
              <h2 style={{ fontSize: '0.95rem', marginTop: 0 }}>إنشاء فاتورة من الطلب</h2>
              <table>
                <thead>
                  <tr>
                    <th>الصنف</th>
                    <th className="num" style={{ width: 100 }}>المتبقي</th>
                    <th className="num" style={{ width: 120 }}>كمية الفوترة الآن</th>
                  </tr>
                </thead>
                <tbody>
                  {lines?.map((l) => {
                    const max = remaining.get(l.item_id) ?? 0;
                    return (
                      <tr key={l.id}>
                        <td>{l.item?.code} · {l.item?.name_ar}</td>
                        <td className="num muted">{fmtMoney(max)} {l.unit?.unit_name ?? l.item?.base_unit_name}</td>
                        <td>
                          <input
                            className="num" inputMode="decimal" disabled={max <= 0}
                            value={invoiceQtys[l.item_id] ?? ''}
                            onChange={(e) => setInvoiceQtys((q) => ({ ...q, [l.item_id]: e.target.value }))}
                            placeholder="0"
                          />
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
              <div className="row" style={{ alignItems: 'center', marginTop: '0.75rem' }}>
                <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
                  <input type="radio" style={{ width: 'auto' }} checked={invoicePaymentMethod === 'credit'} onChange={() => setInvoicePaymentMethod('credit')} /> آجل
                </label>
                <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
                  <input type="radio" style={{ width: 'auto' }} checked={invoicePaymentMethod === 'cash'} onChange={() => setInvoicePaymentMethod('cash')} /> نقدي
                </label>
                {invoicePaymentMethod === 'cash' && (
                  <select value={invoiceCashAccountId} onChange={(e) => setInvoiceCashAccountId(e.target.value)} style={{ width: 220 }}>
                    <option value="">حساب الصندوق/البنك…</option>
                    {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                  </select>
                )}
              </div>
              {err && <p className="error">{err}</p>}
              <button className="btn-primary" disabled={busy} onClick={createInvoice} style={{ marginTop: '0.75rem' }}>إنشاء الفاتورة (مسودة)</button>
            </div>
          )}

          <div className="card" style={{ maxWidth: 460 }}>
            <h2 style={{ fontSize: '0.95rem', marginTop: 0 }}>إلغاء الطلب</h2>
            <p className="muted" style={{ fontSize: '0.9rem' }}>الفواتير الموجودة أصلاً ما بتتأثر — بس ما رح تقدر تفوتر باقي الطلب بعدها.</p>
            <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
            <button className="btn-danger" disabled={busy} onClick={cancelOrder}>إلغاء الطلب</button>
          </div>
        </>
      )}

      {order.status === 'cancelled' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <p className="muted" style={{ marginTop: 0 }}>أُلغي{order.cancel_reason ? ` — ${order.cancel_reason}` : ''}.</p>
        </div>
      )}

      {(orderInvoices?.length ?? 0) > 0 && (
        <>
          <h2 style={{ fontSize: '0.95rem' }}>الفواتير المُنشأة من هذا الطلب</h2>
          <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
            <table>
              <tbody>
                {orderInvoices?.map((inv) => (
                  <tr key={inv.id} className="rowlink" onClick={() => nav(`/sales-invoices/${inv.id}`)}>
                    <td className="mono">#{inv.invoice_no}</td>
                    <td>{fmtDate(inv.invoice_date)}</td>
                    <td><span className={`badge ${inv.status}`}>{inv.status}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      <p style={{ marginTop: '1rem' }}><Link to="/sales-orders">‹ رجوع لقائمة طلبات البيع</Link></p>
    </>
  );
}
