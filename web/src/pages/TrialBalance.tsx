import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';

interface TBRow {
  account_id: string;
  code: string;
  name_ar: string;
  debit: number;
  credit: number;
  balance: number;
}

export default function TrialBalance() {
  const { org } = useOrg();
  const { data, isLoading, error } = useQuery({
    queryKey: ['trial-balance', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<TBRow[]> => {
      const { data, error } = await supabase.rpc('trial_balance', { p_org: org!.id, p_as_of: today() });
      if (error) throw error;
      return data ?? [];
    },
  });

  const totalDr = (data ?? []).reduce((s, r) => s + Number(r.debit), 0);
  const totalCr = (data ?? []).reduce((s, r) => s + Number(r.credit), 0);

  return (
    <>
      <h1>ميزان المراجعة</h1>
      <p className="muted">حتى {today()}</p>
      {error && <p className="error">{translateError((error as Error).message)}</p>}
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 90 }}>الرمز</th>
              <th>الحساب</th>
              <th className="num">مدين</th>
              <th className="num">دائن</th>
              <th className="num">الرصيد</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && (
              <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>
            )}
            {data?.length === 0 && (
              <tr><td colSpan={5} className="muted">لا توجد حركات مرحّلة بعد.</td></tr>
            )}
            {data?.map((r) => (
              <tr key={r.account_id}>
                <td className="mono">{r.code}</td>
                <td>{r.name_ar}</td>
                <td className="num">{r.debit ? fmtMoney(r.debit) : ''}</td>
                <td className="num">{r.credit ? fmtMoney(r.credit) : ''}</td>
                <td className="num" style={{ color: r.balance >= 0 ? 'var(--debit)' : 'var(--credit)' }}>
                  {fmtMoney(Math.abs(r.balance))} {r.balance >= 0 ? 'مدين' : 'دائن'}
                </td>
              </tr>
            ))}
          </tbody>
          {data && data.length > 0 && (
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td colSpan={2}>الإجمالي</td>
                <td className="num">{fmtMoney(totalDr)}</td>
                <td className="num">{fmtMoney(totalCr)}</td>
                <td className="num">{totalDr === totalCr ? 'متوازن ✓' : 'غير متوازن'}</td>
              </tr>
            </tfoot>
          )}
        </table>
      </div>
    </>
  );
}
