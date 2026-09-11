import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Invoice {
  id: string; invoice_no: number; invoice_date: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'credit' | 'cash'; dealer: { name_ar: string } | null;
}
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّلة', void: 'ملغاة' };
const METHOD: Record<string, string> = { credit: 'آجل', cash: 'نقدي' };

export default function SalesInvoices() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['sales-invoices', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Invoice[]> => {
      const { data, error } = await supabase
        .from('sales_invoices')
        .select('id, invoice_no, invoice_date, status, payment_method, dealer:dealer_id(name_ar)')
        .order('invoice_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Invoice[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>فواتير المبيعات</h1>
        <Link to="/sales-invoices/new" className="btn btn-primary">فاتورة جديدة</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>العميل</th>
              <th style={{ width: 80 }}>طريقة الدفع</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={5} className="muted">لا فواتير بعد.</td></tr>}
            {data?.map((inv) => (
              <tr key={inv.id} className="rowlink" onClick={() => nav(`/sales-invoices/${inv.id}`)}>
                <td className="mono">{inv.invoice_no}</td>
                <td>{fmtDate(inv.invoice_date)}</td>
                <td>{inv.dealer?.name_ar}</td>
                <td>{METHOD[inv.payment_method]}</td>
                <td><span className={`badge ${inv.status}`}>{STATUS[inv.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
