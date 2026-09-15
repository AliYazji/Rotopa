import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, fmtPct, today, translateError } from '../lib/format.ts';
import { ItemPicker, type ItemUnitOpt } from '../components/ItemPicker.tsx';
import { PrintInvoice } from '../components/PrintInvoice.tsx';

interface Invoice {
  id: string; invoice_no: number; invoice_date: string; due_date: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'credit' | 'cash'; cash_account_id: string | null; description: string;
  dealer_id: string; warehouse_id: string;
  dealer: { name_ar: string } | null; void_reason: string | null;
}
interface Line {
  id: string; line_no: number; item_id: string; qty: number; unit_price: number; discount_pct: number; line_total: number; unit_cost: number | null;
  unit_id: string | null;
  item: { code: string; name_ar: string; base_unit_name: string; item_units: ItemUnitOpt[] } | null;
  unit: { unit_name: string } | null;
}
interface DealerOpt { id: string; code: string; name_ar: string; }
interface WhOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }

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

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّلة', void: 'ملغاة' };

export default function SalesInvoiceDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org, taxRate, taxEnabled, defaultAccounts } = useOrg();
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
  const [dueDate, setDueDate] = useState('');
  const [desc, setDesc] = useState('');
  const [defaultSalesAccountId, setDefaultSalesAccountId] = useState('');
  const [vatAccountId, setVatAccountId] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: invoice, isLoading } = useQuery({
    queryKey: ['sales-invoice', id],
    enabled: !!id,
    queryFn: async (): Promise<Invoice> => {
      const { data, error } = await supabase.from('sales_invoices')
        .select('id, invoice_no, invoice_date, due_date, status, payment_method, cash_account_id, description, dealer_id, warehouse_id, void_reason, dealer:dealer_id(name_ar)')
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
        .select('id, line_no, item_id, qty, unit_price, discount_pct, line_total, unit_cost, unit_id, item:item_id(code, name_ar, base_unit_name, item_units(id, unit_name, conversion_factor, is_sales_default, is_purchase_default)), unit:unit_id(unit_name)')
        .eq('invoice_id', id).order('line_no');
      if (error) throw error;
      return data as unknown as Line[];
    },
  });

  useEffect(() => {
    if (invoice) {
      setDealerId(invoice.dealer_id); setWarehouseId(invoice.warehouse_id);
      setPaymentMethod(invoice.payment_method);
      if (invoice.cash_account_id) setCashAccountId(invoice.cash_account_id);
      setDesc(invoice.description ?? ''); setDueDate(invoice.due_date);
    }
  }, [invoice]);
  useEffect(() => { if (lines) setEditLines(lines.map(toEditLine)); }, [lines]);
  // org-level defaults (Settings > الحسابات الافتراضية) fill in whatever
  // the loaded draft/document didn't already have — never overrides a real
  // stored value or a choice the user already made on this form
  useEffect(() => {
    setCashAccountId((v) => v || defaultAccounts.cashAccountId);
    setDefaultSalesAccountId((v) => v || defaultAccounts.salesAccountId);
    setVatAccountId((v) => v || defaultAccounts.outputVatAccountId);
  }, [defaultAccounts]);

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
      if (paymentMethod === 'credit' && dueDate < invoice!.invoice_date) throw new Error('تاريخ الاستحقاق لازم يكون بنفس تاريخ الفاتورة أو بعده');
      const valid = editLines.filter((l) => l.itemId && (parseFloat(l.qty) || 0) > 0 && parseFloat(l.unitPrice) >= 0);
      if (valid.length === 0) throw new Error('أضف صنفاً واحداً على الأقل');

      const { error: uErr } = await supabase.from('sales_invoices').update({
        dealer_id: dealerId, warehouse_id: warehouseId, payment_method: paymentMethod,
        cash_account_id: paymentMethod === 'cash' ? cashAccountId : null, description: desc,
        due_date: paymentMethod === 'credit' ? dueDate : invoice!.invoice_date,
      }).eq('id', id);
      if (uErr) throw uErr;

      // draft only, so a clean replace is simplest and safest — no partial-edit drift
      const { error: dErr } = await supabase.from('sales_invoice_lines').delete().eq('invoice_id', id);
      if (dErr) throw dErr;
      const { error: iErr } = await supabase.from('sales_invoice_lines').insert(
        valid.map((l, i) => ({
          invoice_id: id, line_no: i + 1, item_id: l.itemId,
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

  async function postDraft() {
    setErr(null); setBusy(true);
    if (taxEnabled && !vatAccountId) { setBusy(false); return setErr('اختر حساب ضريبة المخرجات'); }
    const { error } = await supabase.rpc('post_sales_invoice', {
      p_invoice_id: id, p_default_sales_account_id: defaultSalesAccountId || null, p_output_vat_account_id: taxEnabled ? vatAccountId : null,
    });
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

  // A posted invoice is intentionally immutable (module 05's core guarantee —
  // it already moved real stock and posted a real journal entry). Fixing a
  // mistake means void it, then correct a copy: this creates a fresh DRAFT
  // with the same header and lines and takes you straight to editing it.
  async function duplicateToDraft() {
    if (!invoice || !lines) return;
    setErr(null); setBusy(true);
    try {
      const { data: newId, error } = await supabase.rpc('create_sales_invoice', {
        p_org: org!.id, p_invoice_date: today(), p_dealer_id: invoice.dealer_id, p_warehouse_id: invoice.warehouse_id,
        p_lines: lines.map((l) => ({ item_id: l.item_id, qty: l.qty, unit_price: l.unit_price, discount_pct: l.discount_pct })),
        p_payment_method: invoice.payment_method, p_cash_account_id: invoice.cash_account_id,
        p_description: invoice.description, p_due_date: invoice.due_date,
      });
      if (error) throw error;
      nav(`/sales-invoices/${newId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  if (isLoading || !invoice) return <p className="muted">جارٍ التحميل…</p>;
  const total = (editing ? editLines : lines ?? []).reduce((s: number, l: any) => {
    if (editing) { const q = parseFloat(l.qty) || 0, p = parseFloat(l.unitPrice) || 0, d = parseFloat(l.discountPct) || 0; return s + q * p * (1 - d / 100); }
    return s + Number(l.line_total);
  }, 0);

  return (
    <>
      {invoice.status === 'posted' && (
        <PrintInvoice
          docTitle="فاتورة مبيعات" docNo={invoice.invoice_no} docDate={invoice.invoice_date}
          dueDate={invoice.payment_method === 'credit' ? invoice.due_date : null}
          partyLabel="العميل" partyName={invoice.dealer?.name_ar ?? ''}
          lines={(lines ?? []).map((l) => ({
            key: l.id, label: `${l.item?.code} · ${l.item?.name_ar}`, qty: l.qty,
            unitLabel: l.unit?.unit_name ?? l.item?.base_unit_name ?? '', unitPrice: l.unit_price,
            discountPct: l.discount_pct, total: l.line_total,
          }))}
          subtotal={total} vat={total * taxRate} total={total * (1 + taxRate)}
        />
      )}
      <div className="no-print">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>فاتورة مبيعات رقم {invoice.invoice_no}</h1>
        <div className="row">
          {invoice.status === 'posted' && <button onClick={() => window.print()}>طباعة</button>}
          <span className={`badge ${invoice.status}`}>{STATUS[invoice.status]}</span>
        </div>
      </div>

      {invoice.status === 'draft' && !editing && (
        <p className="muted">
          {fmtDate(invoice.invoice_date)} · {invoice.dealer?.name_ar} · {invoice.payment_method === 'cash' ? 'نقدي' : `آجل — يستحق ${fmtDate(invoice.due_date)}`} — هاي مسودة، لسا ما ترحّلت.
        </p>
      )}
      {invoice.status !== 'draft' && (
        <p className="muted">
          {fmtDate(invoice.invoice_date)} · {invoice.dealer?.name_ar} · {invoice.payment_method === 'cash' ? 'نقدي' : `آجل — يستحق ${fmtDate(invoice.due_date)}`}
        </p>
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
            {paymentMethod === 'credit' && (
              <div className="field" style={{ width: 160, margin: 0 }}>
                <label>تاريخ الاستحقاق</label>
                <input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
              </div>
            )}
          </div>
          <div className="field"><label>البيان</label><input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>

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
            <tfoot>
              <tr><td colSpan={4}>المجموع قبل الضريبة</td><td className="num">{fmtMoney(total)}</td><td /></tr>
              {taxEnabled && <tr className="muted"><td colSpan={4}>ضريبة القيمة المضافة ({fmtPct(taxRate)})</td><td className="num">{fmtMoney(total * taxRate)}</td><td /></tr>}
              <tr style={{ fontWeight: 700 }}><td colSpan={4}>الإجمالي شامل الضريبة</td><td className="num">{fmtMoney(total * (1 + taxRate))}</td><td /></tr>
            </tfoot>
          </table>
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, itemId: '', itemLabel: '', qty: '1', unitPrice: '', discountPct: '0', baseUnitName: '', unitId: '', units: [] }])} style={{ marginTop: '0.5rem' }}>+ صنف</button>

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
                  <td className="num">{fmtMoney(l.qty)} {l.unit?.unit_name ?? l.item?.base_unit_name}</td>
                  <td className="num">{fmtMoney(l.unit_price)}</td>
                  <td className="num">{l.discount_pct}</td>
                  <td className="num">{fmtMoney(l.line_total)}</td>
                  {invoice.status !== 'draft' && (
                    <td className="num muted">
                      {l.unit_cost != null ? <>{fmtMoney(l.unit_cost)} / {l.item?.base_unit_name}</> : '—'}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={4}>المجموع قبل الضريبة</td>
                <td className="num">{fmtMoney(total)}</td>
                {invoice.status !== 'draft' && <td />}
              </tr>
              {taxEnabled && (
                <tr className="muted">
                  <td colSpan={4}>ضريبة القيمة المضافة ({fmtPct(taxRate)})</td>
                  <td className="num">{fmtMoney(total * taxRate)}</td>
                  {invoice.status !== 'draft' && <td />}
                </tr>
              )}
              <tr style={{ fontWeight: 700 }}>
                <td colSpan={4}>الإجمالي شامل الضريبة</td>
                <td className="num">{fmtMoney(total * (1 + taxRate))}</td>
                {invoice.status !== 'draft' && <td />}
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {invoice.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 460 }}>
          <h2 style={{ fontSize: '0.95rem' }}>ترحيل الفاتورة</h2>
          <p className="muted" style={{ fontSize: '0.85rem' }}>
            {taxEnabled
              ? <>الإجمالي شامل الضريبة ({fmtPct(taxRate)}): <strong>{fmtMoney(total * (1 + taxRate))}</strong> (منها {fmtMoney(total * taxRate)} ضريبة)</>
              : <>الإجمالي (الضريبة معطّلة): <strong>{fmtMoney(total)}</strong></>}
          </p>
          <div className="field">
            <label>حساب المبيعات الافتراضي (لأي صنف بلا حساب خاص)</label>
            <select value={defaultSalesAccountId} onChange={(e) => setDefaultSalesAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
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
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postDraft}>ترحيل</button>
            <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}

      {invoice.status === 'posted' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <p className="muted" style={{ fontSize: '0.9rem', marginTop: 0 }}>
            الفاتورة المرحّلة ثابتة عمداً — حرّكت مخزوناً حقيقياً ورحّلت قيداً حقيقياً، فتعديلها
            بأثر رجعي بيكسر السجل. لتصحيح خطأ: <strong>انسخ</strong> لمسودة جديدة تقدر تعدّلها
            وترحّلها، وبعدين <strong>ألغِ</strong> هاي (أو العكس — حسب حالتك).
          </p>
          <div className="row" style={{ marginBottom: '1rem' }}>
            <button disabled={busy} onClick={duplicateToDraft}>نسخ إلى مسودة قابلة للتعديل</button>
            <Link to={`/sales-returns/new?invoice=${invoice.id}`} className="btn">إنشاء مرجع مبيعات</Link>
          </div>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء الفاتورة</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>
            بينشئ فاتورة مرجع تعكس القيد وتعيد البضاعة للمخزون بالكامل — لإرجاع جزء فقط من الأصناف
            استخدم <strong>إنشاء مرجع مبيعات</strong> بدلاً من الإلغاء الكامل.
          </p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <button className="btn-danger" disabled={busy} onClick={voidInvoice}>إلغاء الفاتورة</button>
        </div>
      )}
      {invoice.status === 'void' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <p className="muted" style={{ marginTop: 0 }}>أُلغيت{invoice.void_reason ? ` — ${invoice.void_reason}` : ''}.</p>
          {err && <p className="error">{err}</p>}
          <button disabled={busy} onClick={duplicateToDraft}>نسخ إلى مسودة قابلة للتعديل</button>
        </div>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/sales-invoices">‹ رجوع لقائمة الفواتير</Link></p>
      </div>
    </>
  );
}
