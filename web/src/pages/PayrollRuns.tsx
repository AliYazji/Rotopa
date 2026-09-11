import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Run {
  id: string; run_no: number; run_date: string; description: string; status: 'draft' | 'posted' | 'void';
}
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function PayrollRuns() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['payroll-runs', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Run[]> => {
      const { data, error } = await supabase
        .from('payroll_runs')
        .select('id, run_no, run_date, description, status')
        .order('run_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as Run[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>كشوف الرواتب</h1>
        <Link to="/payroll/new" className="btn btn-primary">كشف جديد</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>البيان</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={4} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={4} className="muted">لا كشوف رواتب بعد.</td></tr>}
            {data?.map((r) => (
              <tr key={r.id} className="rowlink" onClick={() => nav(`/payroll/${r.id}`)}>
                <td className="mono">{r.run_no}</td>
                <td>{fmtDate(r.run_date)}</td>
                <td>{r.description}</td>
                <td><span className={`badge ${r.status}`}>{STATUS[r.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
