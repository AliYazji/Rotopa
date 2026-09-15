import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Ret {
  id: string; return_no: number; return_date: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'credit' | 'cash'; dealer: { name_ar: string } | null; sales_invoice: { invoice_no: number } | null;
}
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };
const METHOD: Record<string, string> = { credit: 'آجل', cash: 'نقدي' };

export default function SalesReturns() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['sales-returns', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Ret[]> => {
      const { data, error } = await supabase
        .from('sales_returns')
        .select('id, return_no, return_date, status, payment_method, dealer:dealer_id(name_ar), sales_invoice:sales_invoice_id(invoice_no)')
        .order('return_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Ret[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>مرتجعات المبيعات</h1>
        <Link to="/sales-returns/new" className="btn btn-primary">مرجع جديد</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>العميل</th>
              <th style={{ width: 90 }}>الفاتورة الأصلية</th>
              <th style={{ width: 80 }}>طريقة الرد</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={6} className="muted">لا مرتجعات بعد.</td></tr>}
            {data?.map((r) => (
              <tr key={r.id} className="rowlink" onClick={() => nav(`/sales-returns/${r.id}`)}>
                <td className="mono">{r.return_no}</td>
                <td>{fmtDate(r.return_date)}</td>
                <td>{r.dealer?.name_ar}</td>
                <td className="mono">#{r.sales_invoice?.invoice_no}</td>
                <td>{METHOD[r.payment_method]}</td>
                <td><span className={`badge ${r.status}`}>{STATUS[r.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
