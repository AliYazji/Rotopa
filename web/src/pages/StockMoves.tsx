import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Move {
  id: string; move_no: number; move_date: string; move_type: string;
  description: string; status: 'draft' | 'posted' | 'void';
}

const MOVE_TYPE: Record<string, string> = {
  opening: 'رصيد افتتاحي', adjustment_in: 'إضافة', adjustment_out: 'صرف',
  transfer: 'تحويل', purchase_in: 'مشتريات', sale_out: 'مبيعات',
};
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function StockMoves() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['stock-moves', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Move[]> => {
      const { data, error } = await supabase.from('stock_moves')
        .select('id, move_no, move_date, move_type, description, status')
        .order('move_date', { ascending: false }).limit(200);
      if (error) throw error;
      return data as Move[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>حركات المخزون</h1>
        <div className="row">
          <Link to="/stock-moves/new?type=opening" className="btn">رصيد افتتاحي</Link>
          <Link to="/stock-moves/new?type=adjustment_in" className="btn">إضافة</Link>
          <Link to="/stock-moves/new?type=adjustment_out" className="btn">صرف</Link>
          <Link to="/stock-moves/new?type=transfer" className="btn btn-primary">تحويل</Link>
        </div>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>النوع</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>البيان</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={5} className="muted">لا حركات بعد.</td></tr>}
            {data?.map((m) => (
              <tr key={m.id} className="rowlink" onClick={() => nav(`/stock-moves/${m.id}`)}>
                <td className="mono">{m.move_no}</td>
                <td>{MOVE_TYPE[m.move_type] ?? m.move_type}</td>
                <td>{fmtDate(m.move_date)}</td>
                <td>{m.description}</td>
                <td><span className={`badge ${m.status}`}>{STATUS[m.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
