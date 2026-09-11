import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';

interface Order {
  id: string; order_no: number; status: 'open' | 'settled' | 'cancelled'; guest_count: number | null;
  outlet: { name_ar: string } | null; table: { table_no: string } | null;
}
const STATUS: Record<string, string> = { open: 'مفتوح', settled: 'مُسدّد', cancelled: 'ملغى' };
const BADGE: Record<string, string> = { open: 'draft', settled: 'posted', cancelled: 'void' };

export default function PosOrders() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['pos-orders', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Order[]> => {
      const { data, error } = await supabase
        .from('pos_orders')
        .select('id, order_no, status, guest_count, outlet:outlet_id(name_ar), table:table_id(table_no)')
        .order('order_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Order[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>طلبات الكاشير</h1>
        <Link to="/pos-orders/new" className="btn btn-primary">طلب جديد</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th>المنفذ</th>
              <th style={{ width: 90 }}>الطاولة</th>
              <th style={{ width: 80 }}>الضيوف</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={5} className="muted">لا طلبات بعد.</td></tr>}
            {data?.map((o) => (
              <tr key={o.id} className="rowlink" onClick={() => nav(`/pos-orders/${o.id}`)}>
                <td className="mono">{o.order_no}</td>
                <td>{o.outlet?.name_ar}</td>
                <td className="mono">{o.table?.table_no ?? 'سفري'}</td>
                <td className="num">{o.guest_count ?? '—'}</td>
                <td><span className={`badge ${BADGE[o.status]}`}>{STATUS[o.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
