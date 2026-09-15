import { useEffect, useMemo, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, fmtPct, translateError } from '../lib/format.ts';
import { ItemPicker } from '../components/ItemPicker.tsx';

interface Order {
  id: string; order_no: number; status: 'open' | 'settled' | 'cancelled'; guest_count: number | null; notes: string;
  warehouse_id: string; sales_invoice_id: string | null; cancel_reason: string | null;
  outlet: { name_ar: string } | null; table: { table_no: string } | null;
}
interface Line { id: string; line_no: number; item_id: string; qty: number; unit_price: number; line_total: number; notes: string; item: { code: string; name_ar: string; base_unit_name: string } | null; }
interface AccOpt { id: string; code: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; }

const WALKIN_CODE = 'CASH-WALKIN';
const STATUS: Record<string, string> = { open: 'مفتوح', settled: 'مُسدّد', cancelled: 'ملغى' };
const BADGE: Record<string, string> = { open: 'draft', settled: 'posted', cancelled: 'void' };

export default function PosOrderDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org, taxRate, taxEnabled, defaultAccounts } = useOrg();
  const qc = useQueryClient();

  const [qty, setQty] = useState('1');
  const [pickedItem, setPickedItem] = useState<{ id: string; label: string; price: number } | null>(null);
  const [paymentType, setPaymentType] = useState<'credit' | 'cash'>('cash');
  const [dealerId, setDealerId] = useState('');
  const [cashAccountId, setCashAccountId] = useState('');
  const [vatAccountId, setVatAccountId] = useState('');
  const [defaultSalesAccountId, setDefaultSalesAccountId] = useState('');
  const [cancelReason, setCancelReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setCashAccountId((v) => v || defaultAccounts.cashAccountId);
    setVatAccountId((v) => v || defaultAccounts.outputVatAccountId);
    setDefaultSalesAccountId((v) => v || defaultAccounts.salesAccountId);
  }, [defaultAccounts]);

  const { data: order, isLoading } = useQuery({
    queryKey: ['pos-order', id], enabled: !!id,
    queryFn: async (): Promise<Order> => {
      const { data, error } = await supabase.from('pos_orders')
        .select('id, order_no, status, guest_count, notes, warehouse_id, sales_invoice_id, cancel_reason, outlet:outlet_id(name_ar), table:table_id(table_no)')
        .eq('id', id).single();
      if (error) throw error; return data as unknown as Order;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['pos-order-lines', id], enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('pos_order_lines')
        .select('id, line_no, item_id, qty, unit_price, line_total, notes, item:item_id(code, name_ar, base_unit_name)')
        .eq('order_id', id).order('line_no');
      if (error) throw error; return data as unknown as Line[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });
  const { data: customers } = useQuery({
    queryKey: ['customers-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').eq('is_customer', true).order('name_ar').limit(500);
      if (error) throw error; return data as DealerOpt[];
    },
  });
  const { data: walkinDealer } = useQuery({
    queryKey: ['walkin-dealer', org?.id], enabled: !!org,
    queryFn: async (): Promise<{ id: string } | null> => {
      const { data, error } = await supabase.from('dealers').select('id').eq('org_id', org!.id).eq('code', WALKIN_CODE).maybeSingle();
      if (error) throw error; return data;
    },
  });

  const totals = useMemo(() => {
    const subtotal = (lines ?? []).reduce((s, l) => s + Number(l.line_total), 0);
    const vat = subtotal * taxRate;
    return { subtotal, vat, grand: subtotal + vat };
  }, [lines, taxRate]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['pos-order', id] });
    await qc.invalidateQueries({ queryKey: ['pos-order-lines', id] });
    await qc.invalidateQueries({ queryKey: ['pos-orders'] });
  }

  async function addLine() {
    setErr(null); setBusy(true);
    try {
      if (!pickedItem) throw new Error('اختر صنفاً');
      const q = parseFloat(qty) || 0;
      if (q <= 0) throw new Error('أدخل كمية صحيحة');
      const { error } = await supabase.rpc('add_order_line', {
        p_order_id: id, p_item_id: pickedItem.id, p_qty: q, p_unit_price: pickedItem.price,
      });
      if (error) throw error;
      setPickedItem(null); setQty('1');
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function removeLine(lineId: string) {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('pos_order_lines').delete().eq('id', lineId);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function cancelOrder() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('cancel_pos_order', { p_order_id: id, p_reason: cancelReason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function settle() {
    setErr(null);
    if (taxEnabled && !vatAccountId) return setErr('اختر حساب ضريبة المخرجات');
    const effectiveDealerId = dealerId || (paymentType === 'cash' ? walkinDealer?.id : '');
    if (paymentType === 'credit' && (!dealerId || dealerId === walkinDealer?.id)) return setErr('اختر زبوناً مسجّلاً للتسوية الآجلة');
    if (paymentType === 'cash' && !cashAccountId) return setErr('اختر الصندوق');
    if (!effectiveDealerId) return setErr('ما في زبون نقدي عام معرَّف بعد — أنشئه من صفحة الكاشير أولاً');

    setBusy(true);
    try {
      const { data: invoiceId, error } = await supabase.rpc('settle_pos_order', {
        p_order_id: id, p_payment_method: paymentType, p_dealer_id: effectiveDealerId,
        p_cash_account_id: paymentType === 'cash' ? cashAccountId : null,
        p_default_sales_account_id: defaultSalesAccountId || null, p_output_vat_account_id: taxEnabled ? vatAccountId : null,
      });
      if (error) throw error;
      await refresh();
      nav(`/sales-invoices/${invoiceId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  if (isLoading || !order) return <p className="muted">جارٍ التحميل…</p>;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>طلب رقم {order.order_no}</h1>
        <span className={`badge ${BADGE[order.status]}`}>{STATUS[order.status]}</span>
      </div>
      <p className="muted">{order.outlet?.name_ar} · {order.table?.table_no ?? 'سفري'}{order.guest_count ? ` · ${order.guest_count} ضيوف` : ''}</p>

      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
        <table>
          <thead><tr><th>الصنف</th><th className="num" style={{ width: 90 }}>الكمية</th><th className="num" style={{ width: 100 }}>السعر</th><th className="num" style={{ width: 100 }}>الإجمالي</th>{order.status === 'open' && <th style={{ width: 40 }} />}</tr></thead>
          <tbody>
            {(!lines || lines.length === 0) && <tr><td colSpan={5} className="muted">لا أصناف بعد.</td></tr>}
            {lines?.map((l) => (
              <tr key={l.id}>
                <td>{l.item?.code} · {l.item?.name_ar}</td>
                <td className="num">{fmtMoney(l.qty)} {l.item?.base_unit_name}</td>
                <td className="num">{fmtMoney(l.unit_price)}</td>
                <td className="num">{fmtMoney(l.line_total)}</td>
                {order.status === 'open' && <td><button className="btn-danger" onClick={() => removeLine(l.id)}>×</button></td>}
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><td colSpan={3}>المجموع قبل الضريبة</td><td className="num">{fmtMoney(totals.subtotal)}</td>{order.status === 'open' && <td />}</tr>
            {taxEnabled && <tr className="muted"><td colSpan={3}>ضريبة القيمة المضافة ({fmtPct(taxRate)})</td><td className="num">{fmtMoney(totals.vat)}</td>{order.status === 'open' && <td />}</tr>}
            <tr style={{ fontWeight: 700 }}><td colSpan={3}>الإجمالي شامل الضريبة</td><td className="num">{fmtMoney(totals.grand)}</td>{order.status === 'open' && <td />}</tr>
          </tfoot>
        </table>
      </div>

      {err && <p className="error">{err}</p>}

      {order.status === 'open' && (
        <>
          <div className="card" style={{ maxWidth: 460, marginBottom: '1rem' }}>
            <h2 style={{ fontSize: '0.95rem' }}>إضافة صنف</h2>
            <ItemPicker
              initialLabel={pickedItem?.label ?? ''}
              onPick={(it) => setPickedItem({ id: it.id, label: `${it.code} · ${it.name_ar}`, price: it.sales_price })}
            />
            <div className="row" style={{ marginTop: '0.5rem' }}>
              <div className="field" style={{ width: 100 }}><label>الكمية</label><input className="num" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} /></div>
              <button className="btn-primary" disabled={busy} onClick={addLine} style={{ alignSelf: 'flex-end' }}>إضافة</button>
            </div>
          </div>

          <div className="card" style={{ maxWidth: 460, marginBottom: '1rem' }}>
            <h2 style={{ fontSize: '0.95rem' }}>تسوية الطلب</h2>
            <div className="row" style={{ marginBottom: '0.5rem' }}>
              <button style={{ flex: 1 }} className={paymentType === 'cash' ? 'btn-primary' : ''} onClick={() => setPaymentType('cash')}>فوري</button>
              <button style={{ flex: 1 }} className={paymentType === 'credit' ? 'btn-primary' : ''} onClick={() => setPaymentType('credit')}>آجل</button>
            </div>
            {paymentType === 'cash' && (
              <div className="field">
                <label>الصندوق</label>
                <select value={cashAccountId} onChange={(e) => setCashAccountId(e.target.value)}>
                  <option value="">اختر صندوق المبيعات…</option>
                  {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                </select>
              </div>
            )}
            <div className="field">
              <label>{paymentType === 'cash' ? 'الزبون (اختياري — افتراضياً زبون نقدي عام)' : 'الزبون'}</label>
              <select value={dealerId} onChange={(e) => setDealerId(e.target.value)}>
                <option value="">{paymentType === 'cash' ? 'زبون نقدي عام (بدون تحديد)' : '— اختر زبوناً —'}</option>
                {customers?.filter((c) => c.id !== walkinDealer?.id).map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
              </select>
            </div>
            {taxEnabled && (
              <div className="field">
                <label>حساب ضريبة المخرجات</label>
                <select value={vatAccountId} onChange={(e) => setVatAccountId(e.target.value)}>
                  <option value="">—</option>
                  {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                </select>
              </div>
            )}
            <div className="field">
              <label>حساب المبيعات الافتراضي (لصنف بلا حساب خاص)</label>
              <select value={defaultSalesAccountId} onChange={(e) => setDefaultSalesAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
            <button className="btn-primary" disabled={busy || (lines ?? []).length === 0} onClick={settle}>تسوية وترحيل الفاتورة</button>
          </div>

          <div className="card" style={{ maxWidth: 460 }}>
            <h2 style={{ fontSize: '0.95rem' }}>إلغاء الطلب</h2>
            <div className="field"><input placeholder="السبب (اختياري)" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} /></div>
            <button className="btn-danger" disabled={busy} onClick={cancelOrder}>إلغاء الطلب</button>
          </div>
        </>
      )}

      {order.status === 'settled' && order.sales_invoice_id && (
        <p><Link to={`/sales-invoices/${order.sales_invoice_id}`}>عرض فاتورة المبيعات الناتجة ›</Link></p>
      )}
      {order.status === 'cancelled' && (
        <p className="muted">أُلغي{order.cancel_reason ? ` — ${order.cancel_reason}` : ''}.</p>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/pos-orders">‹ رجوع لقائمة الطلبات</Link></p>
    </>
  );
}
