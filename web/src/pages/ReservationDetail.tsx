import { useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Reservation {
  id: string; reservation_no: number; rate_per_night: number;
  planned_check_in: string; planned_check_out: string;
  actual_check_in: string | null; actual_check_out: string | null;
  status: 'booked' | 'checked_in' | 'checked_out' | 'cancelled';
  notes: string; cancel_reason: string | null;
  guest: { name_ar: string } | null; room: { room_no: string; room_type: { name_ar: string } | null } | null;
}
interface NightRow { id: string; night_date: string; amount: number; journal_entry_id: string | null; }

const STATUS: Record<string, string> = { booked: 'محجوزة', checked_in: 'وصل', checked_out: 'غادر', cancelled: 'ملغاة' };
const BADGE: Record<string, string> = { booked: 'draft', checked_in: 'posted', checked_out: 'posted', cancelled: 'void' };

export default function ReservationDetail() {
  const { id } = useParams();
  const qc = useQueryClient();
  const [nightDate, setNightDate] = useState(today());
  const [cancelReason, setCancelReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: res, isLoading } = useQuery({
    queryKey: ['reservation', id], enabled: !!id,
    queryFn: async (): Promise<Reservation> => {
      const { data, error } = await supabase.from('reservations')
        .select(`id, reservation_no, rate_per_night, planned_check_in, planned_check_out, actual_check_in, actual_check_out,
                  status, notes, cancel_reason, guest:guest_id(name_ar), room:room_id(room_no, room_type:room_type_id(name_ar))`)
        .eq('id', id).single();
      if (error) throw error; return data as unknown as Reservation;
    },
  });
  const { data: nights } = useQuery({
    queryKey: ['reservation-nights', id], enabled: !!id,
    queryFn: async (): Promise<NightRow[]> => {
      const { data, error } = await supabase.from('reservation_nights')
        .select('id, night_date, amount, journal_entry_id').eq('reservation_id', id).order('night_date');
      if (error) throw error; return data as NightRow[];
    },
  });

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['reservation', id] });
    await qc.invalidateQueries({ queryKey: ['reservation-nights', id] });
    await qc.invalidateQueries({ queryKey: ['reservations'] });
  }

  async function checkIn() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('check_in_reservation', { p_reservation_id: id });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function checkOut() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('check_out_reservation', { p_reservation_id: id });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function cancel() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('cancel_reservation', { p_reservation_id: id, p_reason: cancelReason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function postNight() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_room_night', { p_reservation_id: id, p_night_date: nightDate });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  if (isLoading || !res) return <p className="muted">جارٍ التحميل…</p>;
  const totalPosted = (nights ?? []).reduce((s, n) => s + Number(n.amount), 0);

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>حجز رقم {res.reservation_no}</h1>
        <span className={`badge ${BADGE[res.status]}`}>{STATUS[res.status]}</span>
      </div>

      <div className="card" style={{ maxWidth: 560, marginBottom: '1rem' }}>
        <table>
          <tbody>
            <tr><td className="muted">النزيل</td><td>{res.guest?.name_ar}</td></tr>
            <tr><td className="muted">الغرفة</td><td>{res.room?.room_no} · {res.room?.room_type?.name_ar}</td></tr>
            <tr><td className="muted">سعر الليلة</td><td className="num">{fmtMoney(res.rate_per_night)}</td></tr>
            <tr><td className="muted">الوصول المخطَّط</td><td>{fmtDate(res.planned_check_in)}</td></tr>
            <tr><td className="muted">المغادرة المخطَّطة</td><td>{fmtDate(res.planned_check_out)}</td></tr>
            {res.actual_check_in && <tr><td className="muted">وصل فعلياً</td><td>{new Date(res.actual_check_in).toLocaleString('ar-EG-u-nu-latn')}</td></tr>}
            {res.actual_check_out && <tr><td className="muted">غادر فعلياً</td><td>{new Date(res.actual_check_out).toLocaleString('ar-EG-u-nu-latn')}</td></tr>}
            <tr><td className="muted">إجمالي المُرحّل</td><td className="num" style={{ fontWeight: 700 }}>{fmtMoney(totalPosted)}</td></tr>
            {res.notes && <tr><td className="muted">ملاحظات</td><td>{res.notes}</td></tr>}
            {res.cancel_reason && <tr><td className="muted">سبب الإلغاء</td><td>{res.cancel_reason}</td></tr>}
          </tbody>
        </table>
      </div>

      {err && <p className="error">{err}</p>}

      {res.status === 'booked' && (
        <div className="card" style={{ maxWidth: 460, marginBottom: '1rem' }}>
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={checkIn}>تسجيل وصول</button>
          </div>
          <h2 style={{ fontSize: '0.95rem', marginTop: '1rem' }}>إلغاء الحجز</h2>
          <div className="field"><input placeholder="السبب (اختياري)" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} /></div>
          <button className="btn-danger" disabled={busy} onClick={cancel}>إلغاء الحجز</button>
        </div>
      )}

      {(res.status === 'checked_in' || res.status === 'checked_out') && (
        <div className="card" style={{ maxWidth: 460, marginBottom: '1rem' }}>
          {res.status === 'checked_in' && (
            <div className="row" style={{ marginBottom: '1rem' }}>
              <button className="btn-primary" disabled={busy} onClick={checkOut}>تسجيل مغادرة</button>
            </div>
          )}
          <h2 style={{ fontSize: '0.95rem' }}>ترحيل ليلة</h2>
          <div className="row" style={{ alignItems: 'flex-end' }}>
            <div className="field" style={{ width: 180 }}>
              <label>التاريخ</label>
              <input type="date" value={nightDate} onChange={(e) => setNightDate(e.target.value)} />
            </div>
            <button disabled={busy} onClick={postNight}>ترحيل</button>
          </div>
        </div>
      )}

      <h2>سجل الليالي المُرحّلة</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
        <table>
          <thead><tr><th>التاريخ</th><th className="num" style={{ width: 130 }}>المبلغ</th><th style={{ width: 100 }}>القيد</th></tr></thead>
          <tbody>
            {(!nights || nights.length === 0) && <tr><td colSpan={3} className="muted">لا ليالٍ مُرحّلة بعد.</td></tr>}
            {nights?.map((n) => (
              <tr key={n.id}>
                <td>{fmtDate(n.night_date)}</td>
                <td className="num">{fmtMoney(n.amount)}</td>
                <td>{n.journal_entry_id && <Link to={`/journals/${n.journal_entry_id}`}>عرض ›</Link>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p style={{ marginTop: '1rem' }}><Link to="/reservations">‹ رجوع لقائمة الحجوزات</Link></p>
    </>
  );
}
