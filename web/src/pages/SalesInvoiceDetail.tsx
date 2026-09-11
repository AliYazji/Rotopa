import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';
import { ItemPicker } from '../components/ItemPicker.tsx';

interface Invoice {
  id: string; invoice_no: number; invoice_date: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'credit' | 'cash'; cash_account_id: string | null; description: string;
  dealer_id: string; warehouse_id: string;
  dealer: { name_ar: string } | null; void_reason: string | null;
}
interface Line {
  id: string; line_no: number; qty: number; unit_price: number; discount_pct: number; line_total: number; unit_cost: number | null;
  item: { code: string; name_ar: string; base_unit_name: string } | null;
}
interface DealerOpt { id: string; code: string; name_ar: string; }
interface WhOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }

interface EditLine { key: number; itemId: string; itemLabel: string; qty: string; unitPrice: string; discountPct: string }
let keySeq = 0;
const toEditLine = (l: Line): EditLine => ({
  key: keySeq++, itemId: '', itemLabel: `${l.item?.code} · ${l.item?.name_ar}`,
  qty: String(l.qty), unitPrice: String(l.unit_price), discountPct: String(l.discount_pct),
});

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّلة', void: 'ملغاة' };

export default function SalesInvoiceDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // draft-edit state
  const [editing, setEditing] = useState(false);
  const [dealerId, setDealerId] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<'credit' | 'cash'>('credit');
  const [cashAccountId, setCashAccountId] = useState('');
  const [desc, setDesc] = useState('');
  const [defaultSalesAccountId, setDefaultSalesAccountId] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: invoice, isLoading } = useQuery({
    queryKey: ['sales-invoice', id],
    enabled: !!id,
    queryFn: async (): Promise<Invoice> => {
      const { data, error } = await supabase.from('sales_invoices')
        .select('id, invoice_no, invoice_date, status, payment_method, cash_account_id, description, dealer_id, warehouse_id, void_reason, dealer:dealer_id(name_ar)')
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as Invoice;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['sales-invoice-lines', id],
    enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('sales_invoice_lines')
        .select('id, line_no, qty, unit_price, discount_pct, line_total, unit_cost, item:item_id(code, name_ar, base_unit_name)')
        .eq('invoice_id', id).order('line_no');
      if (error) throw error;
      return data as unknown as Line[];
    },
  });

  useEffect(() => {
    if (invoice) {
      setDealerId(invoice.dealer_id); setWarehouseId(invoice.warehouse_id);
      setPaymentMethod(invoice.payment_method); setCashAccountId(invoice.cash_account_id ?? '');
      setDesc(invoice.description ?? '');
    }
  }, [invoice]);
  useEffect(() => { if (lines) setEditLines(lines.map(toEditLine)); }, [lines]);

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
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  function setEditLine(key: number, patch: Partial<EditLine>) {
    setEditLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }
  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['sales-invoice', id] });
    await qc.invalidateQueries({ queryKey: ['sales-invoice-lines', id] });
    await qc.invalidateQueries({ queryKey: ['sales-invoices'] });
  }

  async function saveDraft() {
    setErr(null); setBusy(true);
    try {
      if (!dealerId) throw new Error('اختر العميل');
      if (!warehouseId) throw new Error('اختر المستودع');
      if (paymentMethod === 'cash' && !cashAccountId) throw new Error('اختر حساب الصندوق/البنك');
      const valid = editLines.filter((l) => l.itemId && (parseFloat(l.qty) || 0) > 0 && parseFloat(l.unitPrice) >= 0);
      if (valid.length === 0) throw new Error('أضف صنفاً واحداً على الأقل');

      const { error: uErr } = await supabase.from('sales_invoices').update({
        dealer_id: dealerId, warehouse_id: warehouseId, payment_method: paymentMethod,
        cash_account_id: paymentMethod === 'cash' ? cashAccountId : null, description: desc,
      }).eq('id', id);
      if (uErr) throw uErr;

      // draft only, so a clean replace is simplest and safest — no partial-edit drift
      const { error: dErr } = await supabase.from('sales_invoice_lines').delete().eq('invoice_id', id);
      if (dErr) throw dErr;
      const { error: iErr } = await supabase.from('sales_invoice_lines').insert(
        valid.map((l, i) => ({
          invoice_id: id, line_no: i + 1, item_id: l.itemId,
          qty: parseFloat(l.qty), unit_price: parseFloat(l.unitPrice), discount_pct: parseFloat(l.discountPct) || 0,
        })),
      );
      if (iErr) throw iErr;

      setEditing(false);
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function postDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_sales_invoice', { p_invoice_id: id, p_default_sales_account_id: defaultSalesAccountId || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('sales_invoices').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/sales-invoices');
  }

  async function voidInvoice() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('void_sales_invoice', { p_invoice_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  if (isLoading || !invoice) return <p className="muted">جارٍ التحميل…</p>;
  const total = (editing ? editLines : lines ?? []).reduce((s: number, l: any) => {
    if (editing) { const q = parseFloat(l.qty) || 0, p = parseFloat(l.unitPrice) || 0, d = parseFloat(l.discountPct) || 0; return s + q * p * (1 - d / 100); }
    return s + Number(l.line_total);
  }, 0);

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>فاتورة مبيعات رقم {invoice.invoice_no}</h1>
        <span className={`badge ${invoice.status}`}>{STATUS[invoice.status]}</span>
      </div>

      {invoice.status === 'draft' && !editing && (
        <p className="muted">{fmtDate(invoice.invoice_date)} · {invoice.dealer?.name_ar} · {invoice.payment_method === 'cash' ? 'نقدي' : 'آجل'} — هاي مسودة، لسا ما ترحّلت.</p>
      )}
      {invoice.status !== 'draft' && (
        <p className="muted">{fmtDate(invoice.invoice_date)} · {invoice.dealer?.name_ar} · {invoice.payment_method === 'cash' ? 'نقدي' : 'آجل'}</p>
      )}

      {invoice.status === 'draft' && editing ? (
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
          <div className="row" style={{ alignItems: 'center' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'credit'} onChange={() => setPaymentMethod('credit')} /> آجل
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'cash'} onChange={() => setPaymentMethod('cash')} /> نقدي
            </label>
            {paymentMethod === 'cash' && (
              <select value={cashAccountId} onChange={(e) => setCashAccountId(e.target.value)} style={{ width: 220 }}>
                <option value="">حساب الصندوق/البنك…</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            )}
          </div>
          <div className="field"><label>البيان</label><input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>

          <table style={{ marginTop: '0.5rem' }}>
            <thead>
              <tr>
                <th>الصنف</th>
                <th style={{ width: 90 }} className="num">الكمية</th>
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
                      onPick={(it) => setEditLine(l.key, { itemId: it.id, itemLabel: `${it.code} · ${it.name_ar}`, unitPrice: l.unitPrice || String(it.sales_price) })}
                    />
                  </td>
                  <td><input className="num" inputMode="decimal" value={l.qty} onChange={(e) => setEditLine(l.key, { qty: e.target.value })} /></td>
                  <td><input className="num" inputMode="decimal" value={l.unitPrice} onChange={(e) => setEditLine(l.key, { unitPrice: e.target.value })} /></td>
                  <td><input className="num" inputMode="decimal" value={l.discountPct} onChange={(e) => setEditLine(l.key, { discountPct: e.target.value })} /></td>
                  <td>{editLines.length > 1 && <button type="button" onClick={() => setEditLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr style={{ fontWeight: 700 }}><td colSpan={3}>الإجمالي</td><td className="num">{fmtMoney(total)}</td><td /></tr></tfoot>
          </table>
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, itemId: '', itemLabel: '', qty: '1', unitPrice: '', discountPct: '0' }])} style={{ marginTop: '0.5rem' }}>+ صنف</button>

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
                {invoice.status !== 'draft' && <th className="num" style={{ width: 100 }}>التكلفة</th>}
              </tr>
            </thead>
            <tbody>
              {lines?.map((l) => (
                <tr key={l.id}>
                  <td>{l.item?.code} · {l.item?.name_ar}</td>
                  <td className="num">{fmtMoney(l.qty)} {l.item?.base_unit_name}</td>
                  <td className="num">{fmtMoney(l.unit_price)}</td>
                  <td className="num">{l.discount_pct}</td>
                  <td className="num">{fmtMoney(l.line_total)}</td>
                  {invoice.status !== 'draft' && <td className="num muted">{l.unit_cost != null ? fmtMoney(l.unit_cost) : '—'}</td>}
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td colSpan={4}>الإجمالي</td>
                <td className="num">{fmtMoney(total)}</td>
                {invoice.status !== 'draft' && <td />}
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {invoice.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 460 }}>
          <h2 style={{ fontSize: '0.95rem' }}>ترحيل الفاتورة</h2>
          <div className="field">
            <label>حساب المبيعات الافتراضي (لأي صنف بلا حساب خاص)</label>
            <select value={defaultSalesAccountId} onChange={(e) => setDefaultSalesAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postDraft}>ترحيل</button>
            <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}

      {invoice.status === 'posted' && (
        <div className="card" style={{ maxWidth: 420 }}>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء الفاتورة</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>بينشئ فاتورة مرجع تعكس القيد وتعيد البضاعة للمخزون.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <button className="btn-danger" disabled={busy} onClick={voidInvoice}>إلغاء الفاتورة</button>
        </div>
      )}
      {invoice.status === 'void' && (
        <p className="muted">أُلغيت{invoice.void_reason ? ` — ${invoice.void_reason}` : ''}.</p>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/sales-invoices">‹ رجوع لقائمة الفواتير</Link></p>
    </>
  );
}
