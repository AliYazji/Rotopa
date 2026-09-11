import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate } from '../lib/format.ts';

interface Entry {
  id: string;
  entry_no: number;
  entry_date: string;
  description: string;
  status: 'draft' | 'posted' | 'void';
  source_type: string;
}

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function Journals() {
  const { org } = useOrg();
  const nav = useNavigate();
  const { data, isLoading } = useQuery({
    queryKey: ['journals', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Entry[]> => {
      const { data, error } = await supabase
        .from('journal_entries')
        .select('id, entry_no, entry_date, description, status, source_type')
        .order('entry_no', { ascending: false })
        .limit(200);
      if (error) throw error;
      return data as Entry[];
    },
  });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>القيود</h1>
        <Link to="/journals/new" className="btn btn-primary">قيد جديد</Link>
      </div>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 110 }}>التاريخ</th>
              <th>البيان</th>
              <th style={{ width: 110 }}>المصدر</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={5} className="muted">لا قيود بعد.</td></tr>}
            {data?.map((e) => (
              <tr key={e.id} className="rowlink" onClick={() => nav(`/journals/${e.id}`)}>
                <td className="mono">{e.entry_no}</td>
                <td>{fmtDate(e.entry_date)}</td>
                <td>{e.description}</td>
                <td className="muted">{e.source_type}</td>
                <td><span className={`badge ${e.status}`}>{STATUS[e.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
