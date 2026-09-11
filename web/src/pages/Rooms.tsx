import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, translateError } from '../lib/format.ts';

interface RoomType { id: string; code: string; name_ar: string; default_rate: number; revenue_account_id: string | null; is_active: boolean; }
interface Room { id: string; room_no: string; room_type_id: string; floor: string | null; status: string; is_active: boolean; room_type: { name_ar: string } | null; }
interface AccOpt { id: string; code: string; name_ar: string; }

const ROOM_STATUS: Record<string, string> = { available: 'متاحة', occupied: 'مشغولة', cleaning: 'قيد التنظيف', out_of_service: 'خارج الخدمة' };

export default function Rooms() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [typeCode, setTypeCode] = useState('');
  const [typeName, setTypeName] = useState('');
  const [typeRate, setTypeRate] = useState('');
  const [typeRevenueAccountId, setTypeRevenueAccountId] = useState('');

  const [roomNo, setRoomNo] = useState('');
  const [roomTypeId, setRoomTypeId] = useState('');
  const [roomFloor, setRoomFloor] = useState('');

  const { data: roomTypes } = useQuery({
    queryKey: ['room-types', org?.id], enabled: !!org,
    queryFn: async (): Promise<RoomType[]> => {
      const { data, error } = await supabase.from('room_types').select('id, code, name_ar, default_rate, revenue_account_id, is_active').order('code');
      if (error) throw error; return data as RoomType[];
    },
  });
  const { data: rooms } = useQuery({
    queryKey: ['rooms', org?.id], enabled: !!org,
    queryFn: async (): Promise<Room[]> => {
      const { data, error } = await supabase.from('rooms').select('id, room_no, room_type_id, floor, status, is_active, room_type:room_type_id(name_ar)').order('room_no');
      if (error) throw error; return data as unknown as Room[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  async function addRoomType() {
    setErr(null); setBusy(true);
    try {
      if (!typeCode.trim() || !typeName.trim()) throw new Error('أدخل رمز واسم نوع الغرفة');
      const { error } = await supabase.from('room_types').insert({
        org_id: org!.id, code: typeCode.trim(), name_ar: typeName.trim(),
        default_rate: parseFloat(typeRate) || 0, revenue_account_id: typeRevenueAccountId || null,
      });
      if (error) throw error;
      setTypeCode(''); setTypeName(''); setTypeRate(''); setTypeRevenueAccountId('');
      await qc.invalidateQueries({ queryKey: ['room-types'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function addRoom() {
    setErr(null); setBusy(true);
    try {
      if (!roomNo.trim()) throw new Error('أدخل رقم الغرفة');
      if (!roomTypeId) throw new Error('اختر نوع الغرفة');
      const { error } = await supabase.from('rooms').insert({
        org_id: org!.id, room_no: roomNo.trim(), room_type_id: roomTypeId, floor: roomFloor || null,
      });
      if (error) throw error;
      setRoomNo(''); setRoomFloor('');
      await qc.invalidateQueries({ queryKey: ['rooms'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>الغرف وأنواعها</h1>
      {err && <p className="error">{err}</p>}

      <h2 style={{ fontSize: '1rem' }}>أنواع الغرف</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '0.75rem' }}>
        <table>
          <thead><tr><th style={{ width: 90 }}>الرمز</th><th>الاسم</th><th className="num" style={{ width: 110 }}>السعر الافتراضي</th><th>حساب الإيراد</th></tr></thead>
          <tbody>
            {roomTypes?.length === 0 && <tr><td colSpan={4} className="muted">لا أنواع غرف بعد.</td></tr>}
            {roomTypes?.map((t) => (
              <tr key={t.id}>
                <td className="mono">{t.code}</td>
                <td>{t.name_ar}</td>
                <td className="num">{fmtMoney(t.default_rate)}</td>
                <td className="muted">{accounts?.find((a) => a.id === t.revenue_account_id)?.name_ar ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="card" style={{ marginBottom: '1.5rem' }}>
        <div className="row" style={{ flexWrap: 'wrap' }}>
          <div className="field" style={{ width: 110 }}><label>الرمز</label><input value={typeCode} onChange={(e) => setTypeCode(e.target.value)} /></div>
          <div className="field grow"><label>الاسم</label><input value={typeName} onChange={(e) => setTypeName(e.target.value)} /></div>
          <div className="field" style={{ width: 140 }}><label>السعر الافتراضي</label><input className="num" inputMode="decimal" value={typeRate} onChange={(e) => setTypeRate(e.target.value)} /></div>
          <div className="field grow">
            <label>حساب الإيراد</label>
            <select value={typeRevenueAccountId} onChange={(e) => setTypeRevenueAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
        </div>
        <button className="btn-primary" disabled={busy} onClick={addRoomType}>إضافة نوع غرفة</button>
      </div>

      <h2 style={{ fontSize: '1rem' }}>الغرف</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '0.75rem' }}>
        <table>
          <thead><tr><th style={{ width: 90 }}>الرقم</th><th>النوع</th><th style={{ width: 90 }}>الطابق</th><th style={{ width: 110 }}>الحالة</th></tr></thead>
          <tbody>
            {rooms?.length === 0 && <tr><td colSpan={4} className="muted">لا غرف بعد.</td></tr>}
            {rooms?.map((r) => (
              <tr key={r.id}>
                <td className="mono">{r.room_no}</td>
                <td>{r.room_type?.name_ar}</td>
                <td>{r.floor ?? '—'}</td>
                <td><span className="badge">{ROOM_STATUS[r.status] ?? r.status}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="card">
        <div className="row" style={{ flexWrap: 'wrap' }}>
          <div className="field" style={{ width: 120 }}><label>رقم الغرفة</label><input value={roomNo} onChange={(e) => setRoomNo(e.target.value)} /></div>
          <div className="field grow">
            <label>النوع</label>
            <select value={roomTypeId} onChange={(e) => setRoomTypeId(e.target.value)}>
              <option value="">—</option>
              {roomTypes?.map((t) => <option key={t.id} value={t.id}>{t.code} · {t.name_ar}</option>)}
            </select>
          </div>
          <div className="field" style={{ width: 120 }}><label>الطابق (اختياري)</label><input value={roomFloor} onChange={(e) => setRoomFloor(e.target.value)} /></div>
        </div>
        <button className="btn-primary" disabled={busy} onClick={addRoom}>إضافة غرفة</button>
      </div>
    </>
  );
}
