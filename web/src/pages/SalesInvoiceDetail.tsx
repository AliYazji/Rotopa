import { useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney, today } from '../lib/format.ts';

interface Invoice {
  id: string; invoice_no: number; invoice_date: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'credit' | 'cash'; description: string;
  dealer: { name_ar: string } | null; void_reason: string | null;
}
interface Line {
  line_no: number; qty: number; unit_price: number; discount_pct: number; line_total: number; unit_cost: number | null;
  item: { code: string; name_ar: string; base_unit_name: string } | null;
}
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّلة', void: 'ملغاة' };

export default function SalesInvoiceDetail() {
  const { id } = useParams();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: invoice, isLoading } = useQuery({
    queryKey: ['sales-invoice', id],
    enabled: !!id,
    queryFn: async (): Promise<Invoice> => {
      const { data, error } = await supabase.from('sales_invoices')
        .select('id, invoice_no, invoice_date, status, payment_method, description, void_reason, dealer:dealer_id(name_ar)')
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
        .select('line_no, qty, unit_price, discount_pct, line_total, unit_cost, item:item_id(code, name_ar, base_unit_name)')
        .eq('invoice_id', id).order('line_no');
      if (error) throw error;
      return data as unknown as Line[];
    },
  });

  async function voidInvoice() {
    setErr(null);
    setBusy(true);
    const { error } = await supabase.rpc('void_sales_invoice', { p_invoice_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(error.message);
    await qc.invalidateQueries({ queryKey: ['sales-invoice', id] });
  }

  if (isLoading || !invoice) return <p className="muted">جارٍ التحميل…</p>;
  const total = lines?.reduce((s, l) => s + Number(l.line_total), 0) ?? 0;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>فاتورة مبيعات رقم {invoice.invoice_no}</h1>
        <span className={`badge ${invoice.status}`}>{STATUS[invoice.status]}</span>
      </div>
      <p className="muted">{fmtDate(invoice.invoice_date)} · {invoice.dealer?.name_ar} · {invoice.payment_method === 'cash' ? 'نقدي' : 'آجل'}</p>

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
              <tr key={l.line_no}>
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
