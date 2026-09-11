import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Voucher {
  id: string;
  voucher_type: 'receipt' | 'payment';
  voucher_no: number;
  voucher_date: string;
  description: string;
  status: 'draft' | 'posted' | 'void';
  currency_id: string;
  rate: number;
}

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };
const TYPE: Record<string, string> = { receipt: 'قبض', payment: 'صرف' };

export default function Vouchers() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['vouchers', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Voucher[]> => {
      const { data, error } = await supabase
        .from('vouchers')
        .select('id, voucher_type, voucher_no, voucher_date, description, status, currency_id, rate')
        .order('voucher_date', { ascending: false })
        .limit(200);
      if (error) throw error;
      return data as Voucher[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>السندات</h1>
        <div className="row">
          <Link to="/vouchers/new?type=receipt" className="btn btn-primary">سند قبض</Link>
          <Link to="/vouchers/new?type=payment" className="btn">سند صرف</Link>
        </div>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 70 }}>النوع</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>البيان</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={5} className="muted">لا سندات بعد.</td></tr>}
            {data?.map((v) => (
              <tr key={v.id} className="rowlink" onClick={() => nav(`/vouchers/${v.id}`)}>
                <td className="mono">{v.voucher_no}</td>
                <td>{TYPE[v.voucher_type]}</td>
                <td>{fmtDate(v.voucher_date)}</td>
                <td>{v.description}</td>
                <td><span className={`badge ${v.status}`}>{STATUS[v.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
