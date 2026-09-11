import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';

interface DealerOpt { id: string; code: string; name_ar: string; }
interface RoomOpt { id: string; room_no: string; room_type_id: string; room_type: { name_ar: string; default_rate: number } | null; }

function addDays(d: string, n: number) {
  const dt = new Date(d);
  dt.setDate(dt.getDate() + n);
  return dt.toISOString().slice(0, 10);
}

export default function ReservationNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [guestId, setGuestId] = useState('');
  const [roomId, setRoomId] = useState('');
  const [rate, setRate] = useState('');
  const [checkIn, setCheckIn] = useState(today());
  const [checkOut, setCheckOut] = useState(addDays(today(), 1));
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: guests } = useQuery({
    queryKey: ['customers-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').eq('is_customer', true).order('name_ar').limit(500);
      if (error) throw error; return data as DealerOpt[];
    },
  });
  const { data: rooms } = useQuery({
    queryKey: ['rooms-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<RoomOpt[]> => {
      const { data, error } = await supabase.from('rooms')
        .select('id, room_no, room_type_id, room_type:room_type_id(name_ar, default_rate)')
        .eq('is_active', true).order('room_no');
      if (error) throw error; return data as unknown as RoomOpt[];
    },
  });

  const nights = Math.max(0, Math.round((new Date(checkOut).getTime() - new Date(checkIn).getTime()) / 86400000));
  const total = nights * (parseFloat(rate) || 0);

  async function save() {
    setErr(null); setBusy(true);
    try {
      if (!guestId) throw new Error('اختر النزيل');
      if (!roomId) throw new Error('اختر الغرفة');
      if (!(parseFloat(rate) > 0)) throw new Error('أدخل سعر الليلة');
      if (nights <= 0) throw new Error('تاريخ المغادرة لازم يكون بعد تاريخ الوصول');

      const { data: id, error } = await supabase.rpc('create_reservation', {
        p_org: org!.id, p_guest_id: guestId, p_room_id: roomId, p_rate_per_night: parseFloat(rate),
        p_planned_check_in: checkIn, p_planned_check_out: checkOut, p_notes: notes,
      });
      if (error) throw error;
      nav(`/reservations/${id}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>حجز جديد</h1>
      <div className="card" style={{ maxWidth: 560 }}>
        <div className="field">
          <label>النزيل</label>
          <select value={guestId} onChange={(e) => setGuestId(e.target.value)}>
            <option value="">—</option>
            {guests?.map((g) => <option key={g.id} value={g.id}>{g.name_ar}</option>)}
          </select>
        </div>
        <div className="field">
          <label>الغرفة</label>
          <select value={roomId} onChange={(e) => {
            const id = e.target.value;
            setRoomId(id);
            const room = rooms?.find((r) => r.id === id);
            if (room?.room_type && !rate) setRate(String(room.room_type.default_rate));
          }}>
            <option value="">—</option>
            {rooms?.map((r) => <option key={r.id} value={r.id}>{r.room_no} · {r.room_type?.name_ar}</option>)}
          </select>
        </div>
        <div className="row">
          <div className="field" style={{ width: 160 }}>
            <label>تاريخ الوصول</label>
            <input type="date" value={checkIn} onChange={(e) => setCheckIn(e.target.value)} />
          </div>
          <div className="field" style={{ width: 160 }}>
            <label>تاريخ المغادرة</label>
            <input type="date" value={checkOut} onChange={(e) => setCheckOut(e.target.value)} />
          </div>
          <div className="field grow">
            <label>سعر الليلة</label>
            <input className="num" inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} />
          </div>
        </div>
        <p className="muted">{nights} ليلة × {fmtMoney(parseFloat(rate) || 0)} = <strong>{fmtMoney(total)}</strong></p>
        <div className="field">
          <label>ملاحظات</label>
          <input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>حجز</button>
      </div>
    </>
  );
}
