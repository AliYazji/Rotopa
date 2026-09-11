import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Reservation {
  id: string; reservation_no: number; planned_check_in: string; planned_check_out: string;
  status: 'booked' | 'checked_in' | 'checked_out' | 'cancelled';
  guest: { name_ar: string } | null; room: { room_no: string } | null;
}
const STATUS: Record<string, string> = { booked: 'محجوزة', checked_in: 'وصل', checked_out: 'غادر', cancelled: 'ملغاة' };
const BADGE: Record<string, string> = { booked: 'draft', checked_in: 'posted', checked_out: 'posted', cancelled: 'void' };

export default function Reservations() {
  const { org } = useOrg();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [auditDate, setAuditDate] = useState(today());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);

  const { data, isLoading } = useQuery({
    queryKey: ['reservations', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Reservation[]> => {
      const { data, error } = await supabase
        .from('reservations')
        .select('id, reservation_no, planned_check_in, planned_check_out, status, guest:guest_id(name_ar), room:room_id(room_no)')
        .order('reservation_no', { ascending: false }).limit(200);
      if (error) throw error;
      return data as unknown as Reservation[];
    },
  });

  async function runAudit() {
    setErr(null); setResult(null); setBusy(true);
    try {
      const { data, error } = await supabase.rpc('run_night_audit', { p_org: org!.id, p_date: auditDate });
      if (error) throw error;
      const rows = (data as { reservation_id: string; journal_entry_id: string; amount: number }[]) ?? [];
      const total = rows.reduce((s, r) => s + Number(r.amount), 0);
      setResult(rows.length === 0 ? 'ما في حجز يستحق ترحيل ليلة بهذا التاريخ.' : `رُحّل إيراد ${rows.length} حجز بإجمالي ${fmtMoney(total)}.`);
      await qc.invalidateQueries({ queryKey: ['reservations'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>الحجوزات</h1>
        <Link to="/reservations/new" className="btn btn-primary">حجز جديد</Link>
      </div>

      <div className="card" style={{ maxWidth: 460, marginBottom: '1rem' }}>
        <h2 style={{ fontSize: '0.95rem' }}>ترحيل ليلي (كل الحجوزات الواصلة)</h2>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <div className="field" style={{ width: 180 }}>
            <label>ليلة تاريخ</label>
            <input type="date" value={auditDate} onChange={(e) => setAuditDate(e.target.value)} />
          </div>
          <button disabled={busy} onClick={runAudit}>ترحيل الإيراد الليلي</button>
        </div>
        {result && <p className="muted" style={{ fontSize: '0.9rem' }}>{result}</p>}
        {err && <p className="error">{err}</p>}
      </div>

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th style={{ width: 70 }}>#</th>
              <th>النزيل</th>
              <th style={{ width: 90 }}>الغرفة</th>
              <th style={{ width: 110 }}>الوصول</th>
              <th style={{ width: 110 }}>المغادرة</th>
              <th style={{ width: 90 }}>الحالة</th>
            </tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {data?.length === 0 && <tr><td colSpan={6} className="muted">لا حجوزات بعد.</td></tr>}
            {data?.map((r) => (
              <tr key={r.id} className="rowlink" onClick={() => nav(`/reservations/${r.id}`)}>
                <td className="mono">{r.reservation_no}</td>
                <td>{r.guest?.name_ar}</td>
                <td className="mono">{r.room?.room_no}</td>
                <td>{fmtDate(r.planned_check_in)}</td>
                <td>{fmtDate(r.planned_check_out)}</td>
                <td><span className={`badge ${BADGE[r.status]}`}>{STATUS[r.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
