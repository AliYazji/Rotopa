import { useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney } from '../lib/format.ts';

interface Item {
  id: string; code: string; name_ar: string; base_unit_name: string;
  sales_price: number; is_stock_tracked: boolean; barcode: string | null;
  category: { name_ar: string } | null;
}
interface Balance { warehouse: { code: string; name_ar: string }; qty: number; avg_cost: number; }
interface MoveLine {
  base_qty: number; direction: 'in' | 'out'; unit_cost: number;
  warehouse: { name_ar: string };
  move: { move_no: number; move_date: string; move_type: string; status: string; description: string };
}

const MOVE_TYPE: Record<string, string> = {
  opening: 'رصيد افتتاحي', adjustment_in: 'إضافة', adjustment_out: 'صرف',
  transfer: 'تحويل', purchase_in: 'مشتريات', sale_out: 'مبيعات',
};

export default function ItemDetail() {
  const { id } = useParams();

  const { data: item, isLoading } = useQuery({
    queryKey: ['item', id],
    enabled: !!id,
    queryFn: async (): Promise<Item> => {
      const { data, error } = await supabase.from('items')
        .select('id, code, name_ar, base_unit_name, sales_price, is_stock_tracked, barcode, category:category_id(name_ar)')
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as Item;
    },
  });

  const { data: balances } = useQuery({
    queryKey: ['item-balances', id],
    enabled: !!id,
    queryFn: async (): Promise<Balance[]> => {
      const { data, error } = await supabase.from('item_warehouse_balances')
        .select('qty, avg_cost, warehouse:warehouse_id(code, name_ar)').eq('item_id', id);
      if (error) throw error;
      return data as unknown as Balance[];
    },
  });

  const { data: history } = useQuery({
    queryKey: ['item-history', id],
    enabled: !!id,
    queryFn: async (): Promise<MoveLine[]> => {
      const { data, error } = await supabase.from('stock_move_lines')
        .select('base_qty, direction, unit_cost, warehouse:warehouse_id(name_ar), move:move_id(move_no, move_date, move_type, status, description)')
        .eq('item_id', id).order('created_at', { ascending: false }).limit(30);
      if (error) throw error;
      return (data as unknown as MoveLine[]).filter((l) => l.move.status === 'posted');
    },
  });

  if (isLoading || !item) return <p className="muted">جارٍ التحميل…</p>;
  const totalQty = balances?.reduce((s, b) => s + Number(b.qty), 0) ?? 0;

  return (
    <>
      <h1>{item.name_ar}</h1>
      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap', marginBottom: '1.25rem' }}>
        <div className="card" style={{ flex: '1 1 260px' }}>
          <h2 style={{ fontSize: '0.95rem' }}>البيانات</h2>
          <table>
            <tbody>
              <tr><td className="muted">الرمز</td><td className="mono">{item.code}</td></tr>
              <tr><td className="muted">الفئة</td><td>{item.category?.name_ar ?? '—'}</td></tr>
              <tr><td className="muted">الوحدة</td><td>{item.base_unit_name}</td></tr>
              <tr><td className="muted">الباركود</td><td className="mono">{item.barcode ?? '—'}</td></tr>
              <tr><td className="muted">سعر البيع</td><td className="num">{fmtMoney(item.sales_price)}</td></tr>
              <tr><td className="muted">تتبّع المخزون</td><td>{item.is_stock_tracked ? 'نعم' : 'لا (صنف خدمي)'}</td></tr>
            </tbody>
          </table>
        </div>
        {item.is_stock_tracked && (
          <div className="card" style={{ flex: '1 1 200px', display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center' }}>
            <div className="muted" style={{ fontSize: '0.85rem' }}>الرصيد الحالي</div>
            <div style={{ fontSize: '1.8rem', fontWeight: 700, fontFamily: 'var(--mono)' }}>{fmtMoney(totalQty)}</div>
            <div className="muted" style={{ fontSize: '0.85rem' }}>{item.base_unit_name}</div>
          </div>
        )}
      </div>

      {item.is_stock_tracked && (
        <>
          <h2>الرصيد حسب المستودع</h2>
          <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1.25rem' }}>
            <table>
              <thead><tr><th>المستودع</th><th className="num" style={{ width: 120 }}>الكمية</th><th className="num" style={{ width: 120 }}>متوسط التكلفة</th></tr></thead>
              <tbody>
                {(!balances || balances.length === 0) && <tr><td colSpan={3} className="muted">لا رصيد بعد.</td></tr>}
                {balances?.filter((b) => Number(b.qty) !== 0).map((b, i) => (
                  <tr key={i}><td>{b.warehouse.name_ar}</td><td className="num">{fmtMoney(b.qty)}</td><td className="num">{fmtMoney(b.avg_cost)}</td></tr>
                ))}
              </tbody>
            </table>
          </div>

          <h2>حركة المخزون</h2>
          <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
            <table>
              <thead>
                <tr><th style={{ width: 90 }}>التاريخ</th><th style={{ width: 100 }}>النوع</th><th>المستودع</th><th className="num" style={{ width: 100 }}>وارد</th><th className="num" style={{ width: 100 }}>صادر</th></tr>
              </thead>
              <tbody>
                {(!history || history.length === 0) && <tr><td colSpan={5} className="muted">لا حركات بعد.</td></tr>}
                {history?.map((l, i) => (
                  <tr key={i}>
                    <td>{fmtDate(l.move.move_date)}</td>
                    <td>{MOVE_TYPE[l.move.move_type] ?? l.move.move_type}</td>
                    <td>{l.warehouse.name_ar}</td>
                    <td className="num">{l.direction === 'in' ? fmtMoney(l.base_qty) : ''}</td>
                    <td className="num">{l.direction === 'out' ? fmtMoney(l.base_qty) : ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
