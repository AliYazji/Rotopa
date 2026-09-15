import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney } from '../lib/format.ts';

interface Order {
  id: string; order_no: number; order_date: string; qty: number; status: 'draft' | 'posted' | 'void';
  finished_item: { code: string; name_ar: string } | null;
}
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function ManufacturingOrders() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['manufacturing-orders', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Order[]> => {
      const { data, error } = await supabase.from('manufacturing_orders')
        .select('id, order_no, order_date, qty, status, finished_item:finished_item_id(code, name_ar)')
        .order('order_date', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Order[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>أوامر التصنيع</h1>
        <Link to="/manufacturing-orders/new" className="btn btn-primary">أمر تصنيع جديد</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>الصنف المُصنَّع</th>
              <th className="num" style={{ width: 100 }}>الكمية</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={5} className="muted">لا أوامر تصنيع بعد.</td></tr>}
            {data?.map((o) => (
              <tr key={o.id} className="rowlink" onClick={() => nav(`/manufacturing-orders/${o.id}`)}>
                <td className="mono">{o.order_no}</td>
                <td className="mono">{fmtDate(o.order_date)}</td>
                <td>{o.finished_item?.code} · {o.finished_item?.name_ar}</td>
                <td className="num">{fmtMoney(o.qty)}</td>
                <td><span className={`badge ${o.status}`}>{STATUS[o.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
