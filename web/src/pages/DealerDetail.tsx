import { useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney } from '../lib/format.ts';

interface Dealer {
  id: string;
  code: string;
  name_ar: string;
  is_customer: boolean;
  is_supplier: boolean;
  is_employee: boolean;
  account_id: string;
  phone: string | null;
  email: string | null;
  address: string | null;
  city: string | null;
  credit_limit: number;
  is_active: boolean;
}
interface LedgerRow {
  entry_no: number;
  entry_date: string;
  description: string;
  debit: number;
  credit: number;
  running: number;
}

export default function DealerDetail() {
  const { id } = useParams();

  const { data: dealer, isLoading: loadingDealer } = useQuery({
    queryKey: ['dealer', id],
    enabled: !!id,
    queryFn: async (): Promise<Dealer> => {
      const { data, error } = await supabase.from('dealers').select('*').eq('id', id).single();
      if (error) throw error;
      return data as Dealer;
    },
  });

  const { data: ledger, isLoading: loadingLedger } = useQuery({
    queryKey: ['dealer-ledger', dealer?.account_id],
    enabled: !!dealer?.account_id,
    queryFn: async (): Promise<LedgerRow[]> => {
      const { data, error } = await supabase.rpc('account_ledger', { p_account_id: dealer!.account_id });
      if (error) throw error;
      return data as LedgerRow[];
    },
  });

  const { data: balance } = useQuery({
    queryKey: ['dealer-balance', dealer?.account_id],
    enabled: !!dealer?.account_id,
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('account_balance', { p_account_id: dealer!.account_id });
      if (error) throw error;
      return data as number;
    },
  });

  if (loadingDealer || !dealer) return <p className="muted">جارٍ التحميل…</p>;

  return (
    <>
      <h1>{dealer.name_ar}</h1>
      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap', marginBottom: '1.25rem' }}>
        <div className="card" style={{ flex: '1 1 260px' }}>
          <h2 style={{ fontSize: '0.95rem' }}>البيانات</h2>
          <table>
            <tbody>
              <tr><td className="muted">الرمز</td><td className="mono">{dealer.code}</td></tr>
              <tr><td className="muted">الأدوار</td><td>
                {dealer.is_customer && <span className="badge">عميل</span>}{' '}
                {dealer.is_supplier && <span className="badge">مورد</span>}{' '}
                {dealer.is_employee && <span className="badge">موظف</span>}
              </td></tr>
              <tr><td className="muted">الهاتف</td><td className="mono">{dealer.phone || '—'}</td></tr>
              <tr><td className="muted">البريد</td><td className="mono">{dealer.email || '—'}</td></tr>
              <tr><td className="muted">المدينة</td><td>{dealer.city || '—'}</td></tr>
              <tr><td className="muted">العنوان</td><td>{dealer.address || '—'}</td></tr>
              <tr><td className="muted">حد الائتمان</td><td className="num">{fmtMoney(dealer.credit_limit)}</td></tr>
            </tbody>
          </table>
        </div>
        <div className="card" style={{ flex: '1 1 200px', display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center' }}>
          <div className="muted" style={{ fontSize: '0.85rem' }}>الرصيد الحالي</div>
          <div style={{ fontSize: '1.8rem', fontWeight: 700, fontFamily: 'var(--mono)', color: (balance ?? 0) >= 0 ? 'var(--debit)' : 'var(--credit)' }}>
            {fmtMoney(Math.abs(balance ?? 0))}
          </div>
          <div className="muted" style={{ fontSize: '0.85rem' }}>{(balance ?? 0) >= 0 ? 'مدين (له/علينا)' : 'دائن (منه)'}</div>
        </div>
      </div>

      <h2>كشف الحساب</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>البيان</th>
              <th className="num" style={{ width: 110 }}>مدين</th>
              <th className="num" style={{ width: 110 }}>دائن</th>
              <th className="num" style={{ width: 120 }}>الرصيد</th>
            </tr>
          </thead>
          <tbody>
            {loadingLedger && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {ledger?.length === 0 && <tr><td colSpan={6} className="muted">لا حركات مرحّلة بعد.</td></tr>}
            {ledger?.map((l) => (
              <tr key={l.entry_no}>
                <td className="mono">{l.entry_no}</td>
                <td>{fmtDate(l.entry_date)}</td>
                <td>{l.description}</td>
                <td className="num">{l.debit ? fmtMoney(l.debit) : ''}</td>
                <td className="num">{l.credit ? fmtMoney(l.credit) : ''}</td>
                <td className="num">{fmtMoney(l.running)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
