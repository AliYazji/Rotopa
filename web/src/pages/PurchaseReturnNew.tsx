import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams, Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, translateError } from '../lib/format.ts';

interface InvoiceOpt { id: string; invoice_no: number; invoice_date: string; dealer: { name_ar: string } | null; }
interface InvLine { item_id: string; qty: number; unit_price: number; item: { code: string; name_ar: string; base_unit_name: string } | null; }
interface ReturnedRow { item_id: string; qty: number; purchase_returns: { status: string; purchase_invoice_id: string } }
interface AccOpt { id: string; code: string; name_ar: string; }

export default function PurchaseReturnNew() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const preselected = params.get('invoice') ?? '';
  const [invoiceId, setInvoiceId] = useState(preselected);
  const [qtys, setQtys] = useState<Record<string, string>>({});
  const [paymentMethod, setPaymentMethod] = useState<'credit' | 'cash'>('credit');
  const [cashAccountId, setCashAccountId] = useState('');
  const [desc, setDesc] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: invoices } = useQuery({
    queryKey: ['returnable-purchase-invoices', org?.id],
    enabled: !!org && !preselected,
    queryFn: async (): Promise<InvoiceOpt[]> => {
      const { data, error } = await supabase.from('purchase_invoices')
        .select('id, invoice_no, invoice_date, dealer:dealer_id(name_ar)')
        .eq('status', 'posted').order('invoice_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as InvoiceOpt[];
    },
  });

  const { data: invoice } = useQuery({
    queryKey: ['purchase-invoice-header-for-return', invoiceId],
    enabled: !!invoiceId,
    queryFn: async () => {
      const { data, error } = await supabase.from('purchase_invoices')
        .select('id, invoice_no, dealer:dealer_id(name_ar)')
        .eq('id', invoiceId).single();
      if (error) throw error;
      return data as unknown as { id: string; invoice_no: number; dealer: { name_ar: string } | null };
    },
  });

  const { data: lines } = useQuery({
    queryKey: ['purchase-invoice-lines-for-return', invoiceId],
    enabled: !!invoiceId,
    queryFn: async (): Promise<InvLine[]> => {
      const { data, error } = await supabase.from('purchase_invoice_lines')
        .select('item_id, qty, unit_price, item:item_id(code, name_ar, base_unit_name)')
        .eq('invoice_id', invoiceId);
      if (error) throw error;
      return data as unknown as InvLine[];
    },
  });

  const { data: returnedRows } = useQuery({
    queryKey: ['purchase-return-lines-agg', invoiceId],
    enabled: !!invoiceId,
    queryFn: async (): Promise<ReturnedRow[]> => {
      const { data, error } = await supabase.from('purchase_return_lines')
        .select('item_id, qty, purchase_returns!inner(status, purchase_invoice_id)')
        .eq('purchase_returns.purchase_invoice_id', invoiceId).eq('purchase_returns.status', 'posted');
      if (error) throw error;
      return data as unknown as ReturnedRow[];
    },
  });

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  const remaining = useMemo(() => {
    const already = new Map<string, number>();
    for (const r of returnedRows ?? []) already.set(r.item_id, (already.get(r.item_id) ?? 0) + Number(r.qty));
    const m = new Map<string, number>();
    for (const l of lines ?? []) m.set(l.item_id, Number(l.qty) - (already.get(l.item_id) ?? 0));
    return m;
  }, [lines, returnedRows]);

  async function submit() {
    setErr(null);
    const rows = (lines ?? [])
      .map((l) => ({ item_id: l.item_id, qty: parseFloat(qtys[l.item_id] || '0') || 0 }))
      .filter((r) => r.qty > 0);
    if (rows.length === 0) return setErr('أدخل كمية للإرجاع في صنف واحد على الأقل');
    for (const r of rows) {
      const max = remaining.get(r.item_id) ?? 0;
      if (r.qty > max) return setErr(`الكمية المطلوب إرجاعها أكبر من المتاح (${fmtMoney(max)})`);
    }
    if (paymentMethod === 'cash' && !cashAccountId) return setErr('اختر حساب الصندوق/البنك لاستلام الرد النقدي');
    setBusy(true);
    try {
      const { data: newId, error } = await supabase.rpc('create_purchase_return', {
        p_org: org!.id, p_purchase_invoice_id: invoiceId, p_lines: rows,
        p_payment_method: paymentMethod, p_cash_account_id: paymentMethod === 'cash' ? cashAccountId : null,
        p_description: desc,
      });
      if (error) throw error;
      nav(`/purchase-returns/${newId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>مرجع مشتريات جديد</h1>

      {!preselected && (
        <div className="card" style={{ maxWidth: 560 }}>
          <div className="field">
            <label>الفاتورة المرجَع عليها</label>
            <select value={invoiceId} onChange={(e) => { setInvoiceId(e.target.value); setQtys({}); }}>
              <option value="">—</option>
              {invoices?.map((i) => (
                <option key={i.id} value={i.id}>
                  #{i.invoice_no} · {fmtDate(i.invoice_date)} · {i.dealer?.name_ar}
                </option>
              ))}
            </select>
          </div>
        </div>
      )}

      {invoiceId && invoice && (
        <div className="card">
          <p className="muted" style={{ marginTop: 0 }}>مرجَع على فاتورة رقم {invoice.invoice_no} · {invoice.dealer?.name_ar}</p>

          <div style={{ overflowX: 'auto' }}>
          <table>
            <thead>
              <tr>
                <th>الصنف</th>
                <th className="num" style={{ width: 90 }}>الكمية المشتراة</th>
                <th className="num" style={{ width: 90 }}>سعر الوحدة</th>
                <th className="num" style={{ width: 90 }}>المتاح للإرجاع</th>
                <th className="num" style={{ width: 110 }}>كمية الإرجاع</th>
              </tr>
            </thead>
            <tbody>
              {lines?.map((l) => {
                const max = remaining.get(l.item_id) ?? 0;
                return (
                  <tr key={l.item_id}>
                    <td>{l.item?.code} · {l.item?.name_ar}</td>
                    <td className="num">{fmtMoney(l.qty)} {l.item?.base_unit_name}</td>
                    <td className="num">{fmtMoney(l.unit_price)}</td>
                    <td className="num muted">{fmtMoney(max)}</td>
                    <td>
                      <input
                        className="num" inputMode="decimal" disabled={max <= 0}
                        value={qtys[l.item_id] ?? ''}
                        onChange={(e) => setQtys((q) => ({ ...q, [l.item_id]: e.target.value }))}
                        placeholder="0"
                      />
                    </td>
                  </tr>
                );
              })}
              {lines?.length === 0 && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            </tbody>
          </table>
          </div>

          <div className="row" style={{ alignItems: 'center', marginTop: '0.75rem' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'credit'} onChange={() => setPaymentMethod('credit')} /> خصم من حساب المورّد (آجل)
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'cash'} onChange={() => setPaymentMethod('cash')} /> استرداد نقدي فوري
            </label>
            {paymentMethod === 'cash' && (
              <select value={cashAccountId} onChange={(e) => setCashAccountId(e.target.value)} style={{ width: 220 }}>
                <option value="">حساب الصندوق/البنك…</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            )}
          </div>
          <div className="field"><label>البيان (اختياري)</label><input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>

          {err && <p className="error">{err}</p>}
          <div className="row" style={{ marginTop: '1rem' }}>
            <button className="btn-primary" disabled={busy} onClick={submit}>إنشاء المرجع</button>
          </div>
        </div>
      )}

      <p style={{ marginTop: '1rem' }}><Link to="/purchase-returns">‹ رجوع لقائمة مرتجعات المشتريات</Link></p>
    </>
  );
}
