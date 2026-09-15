import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, translateError } from '../lib/format.ts';

interface Summary {
  cash_balance: number; ar_balance: number; ap_balance: number;
  sales_this_month: number; purchases_this_month: number;
  trial_balance_debit: number; trial_balance_credit: number;
  today_period_status: string | null; today_period_label: string | null; fiscal_year_status: string | null;
  draft_sales_invoices: number; draft_purchase_invoices: number;
  open_sales_orders: number; open_purchase_orders: number; pending_invitations: number;
}
interface LogRow {
  id: number; table_name: string; action: 'INSERT' | 'UPDATE' | 'DELETE'; user_email: string | null; at: string;
}

const TABLE_LABEL: Record<string, string> = {
  accounts: 'الحسابات', currencies: 'العملات', journal_entries: 'القيود', vouchers: 'السندات',
  cheques: 'الشيكات', dealers: 'الأطراف', items: 'الأصناف', stock_moves: 'حركات المخزون',
  sales_invoices: 'فاتورة مبيعات', purchase_invoices: 'فاتورة مشتريات', sales_returns: 'مرتجع مبيعات',
  purchase_returns: 'مرتجع مشتريات', sales_orders: 'طلب بيع', purchase_orders: 'طلب شراء',
  fixed_assets: 'أصل ثابت', payroll_runs: 'كشف رواتب', roles: 'الأدوار', memberships: 'العضويات',
  fiscal_periods: 'الفترات المحاسبية',
};
const ACTION_LABEL: Record<string, string> = { INSERT: 'إضافة', UPDATE: 'تعديل', DELETE: 'حذف' };

function Kpi({ label, value, to }: { label: string; value: string; to?: string }) {
  const body = (
    <div className="card">
      <div className="muted" style={{ fontSize: '0.82rem' }}>{label}</div>
      <div style={{ fontSize: '1.5rem', fontWeight: 700, marginTop: '0.2rem' }}>{value}</div>
    </div>
  );
  return to ? <Link to={to} style={{ color: 'inherit' }}>{body}</Link> : body;
}

export default function Dashboard() {
  const { org } = useOrg();

  const { data: s, isLoading, error } = useQuery({
    queryKey: ['dashboard-summary', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Summary> => {
      const { data, error } = await supabase.rpc('dashboard_summary', { p_org: org!.id });
      if (error) throw error;
      const row = (data as Summary[])[0];
      if (!row) throw new Error('no summary row returned');
      return row;
    },
  });

  const { data: recent } = useQuery({
    queryKey: ['dashboard-recent-activity', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<LogRow[]> => {
      const { data, error } = await supabase.rpc('audit_log_query', { p_org: org!.id, p_limit: 8 });
      if (error) throw error;
      return data as LogRow[];
    },
  });

  const balanced = s ? Math.round(s.trial_balance_debit * 100) === Math.round(s.trial_balance_credit * 100) : true;
  const worklistTotal = s
    ? s.draft_sales_invoices + s.draft_purchase_invoices + s.open_sales_orders + s.open_purchase_orders + s.pending_invitations
    : 0;

  return (
    <>
      <h1>لوحة التحكم</h1>
      {error && <p className="error">{translateError((error as Error).message)}</p>}
      {isLoading && <p className="muted">جارٍ التحميل…</p>}

      {s && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: '0.75rem' }}>
            <Kpi label="النقد وشبه النقد" value={fmtMoney(s.cash_balance)} />
            <Kpi label="ذمم العملاء (آجل)" value={fmtMoney(s.ar_balance)} to="/ar-aging" />
            <Kpi label="ذمم الموردين (آجل)" value={fmtMoney(s.ap_balance)} to="/ap-aging" />
            <Kpi label="مبيعات هذا الشهر" value={fmtMoney(s.sales_this_month)} to="/sales-invoices" />
            <Kpi label="مشتريات هذا الشهر" value={fmtMoney(s.purchases_this_month)} to="/purchase-invoices" />
          </div>

          <div className="row" style={{ marginTop: '1rem', alignItems: 'stretch' }}>
            <div className="card grow">
              <h2>حالة الفترة المحاسبية</h2>
              <p style={{ margin: 0 }}>
                {s.today_period_label ?? '—'} —{' '}
                <span className={`badge ${s.today_period_status === 'open' ? 'posted' : 'void'}`}>
                  {s.today_period_status === 'open' ? 'مفتوحة' : s.today_period_status === 'closed' ? 'مقفلة' : '—'}
                </span>
                {' · السنة المالية '}
                <span className={`badge ${s.fiscal_year_status === 'open' ? 'posted' : 'void'}`}>
                  {s.fiscal_year_status === 'open' ? 'مفتوحة' : 'مقفلة'}
                </span>
              </p>
              <p className="muted" style={{ fontSize: '0.85rem' }}><Link to="/periods">إدارة الفترات ›</Link></p>
            </div>
            <div className="card grow">
              <h2>ميزان المراجعة</h2>
              <p style={{ margin: 0 }}>
                <span className="mono">{fmtMoney(s.trial_balance_debit)}</span> = <span className="mono">{fmtMoney(s.trial_balance_credit)}</span>{' '}
                <span className={`badge ${balanced ? 'posted' : 'void'}`}>{balanced ? 'متوازن' : 'غير متوازن'}</span>
              </p>
              <p className="muted" style={{ fontSize: '0.85rem' }}><Link to="/trial-balance">التفاصيل ›</Link></p>
            </div>
          </div>

          <div className="card" style={{ marginTop: '1rem' }}>
            <h2>بانتظار الإجراء {worklistTotal > 0 && <span className="badge void" style={{ marginInlineStart: '0.4rem' }}>{worklistTotal}</span>}</h2>
            {worklistTotal === 0 ? (
              <p className="muted" style={{ margin: 0 }}>لا يوجد شيء بانتظار الإجراء حالياً.</p>
            ) : (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '0.5rem' }}>
                {s.draft_sales_invoices > 0 && (
                  <Link to="/sales-invoices">فواتير مبيعات مسودة: <b>{s.draft_sales_invoices}</b></Link>
                )}
                {s.draft_purchase_invoices > 0 && (
                  <Link to="/purchase-invoices">فواتير مشتريات مسودة: <b>{s.draft_purchase_invoices}</b></Link>
                )}
                {s.open_sales_orders > 0 && (
                  <Link to="/sales-orders">طلبات بيع مؤكَّدة لم تُفوتَر بالكامل: <b>{s.open_sales_orders}</b></Link>
                )}
                {s.open_purchase_orders > 0 && (
                  <Link to="/purchase-orders">طلبات شراء مؤكَّدة لم تُفوتَر بالكامل: <b>{s.open_purchase_orders}</b></Link>
                )}
                {s.pending_invitations > 0 && (
                  <Link to="/team">دعوات فريق معلَّقة: <b>{s.pending_invitations}</b></Link>
                )}
              </div>
            )}
          </div>
        </>
      )}

      <div className="card" style={{ marginTop: '1rem' }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <h2>آخر النشاطات</h2>
          <Link to="/audit-log" style={{ fontSize: '0.85rem' }}>سجل التدقيق الكامل ›</Link>
        </div>
        <div style={{ overflowX: 'auto' }}>
          <table>
            <tbody>
              {!recent?.length && <tr><td className="muted">لا يوجد نشاط بعد.</td></tr>}
              {recent?.map((r) => (
                <tr key={r.id}>
                  <td className="mono" style={{ width: 140 }}>{fmtDate(r.at)}</td>
                  <td><span className={`badge ${r.action === 'DELETE' ? 'void' : r.action === 'INSERT' ? 'posted' : 'draft'}`}>{ACTION_LABEL[r.action]}</span></td>
                  <td>{TABLE_LABEL[r.table_name] ?? r.table_name}</td>
                  <td className="muted">{r.user_email ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
