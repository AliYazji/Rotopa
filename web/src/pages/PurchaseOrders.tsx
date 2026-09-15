import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Order {
  id: string; order_no: number; order_date: string; status: 'draft' | 'confirmed' | 'cancelled';
  dealer: { name_ar: string } | null;
}
const STATUS: Record<string, string> = { draft: 'مسودة', confirmed: 'مؤكَّد', cancelled: 'ملغى' };

export default function PurchaseOrders() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['purchase-orders', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Order[]> => {
      const { data, error } = await supabase
        .from('purchase_orders')
        .select('id, order_no, order_date, status, dealer:dealer_id(name_ar)')
        .order('order_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Order[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>طلبات الشراء</h1>
        <Link to="/purchase-orders/new" className="btn btn-primary">طلب جديد</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>المورّد</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={4} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={4} className="muted">لا طلبات بعد.</td></tr>}
            {data?.map((o) => (
              <tr key={o.id} className="rowlink" onClick={() => nav(`/purchase-orders/${o.id}`)}>
                <td className="mono">{o.order_no}</td>
                <td>{fmtDate(o.order_date)}</td>
                <td>{o.dealer?.name_ar}</td>
                <td><span className={`badge ${o.status === 'confirmed' ? 'posted' : o.status === 'cancelled' ? 'void' : ''}`}>{STATUS[o.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
