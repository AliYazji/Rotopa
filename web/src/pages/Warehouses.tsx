import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface Wh {
  id: string; code: string; name_ar: string; name_en: string | null;
  parent_id: string | null; is_active: boolean;
}

type EditState = { code: string; name_ar: string; name_en: string; parent_id: string };
const emptyEdit: EditState = { code: '', name_ar: '', name_en: '', parent_id: '' };

export default function Warehouses() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editId, setEditId] = useState<string | null>(null);
  const [edit, setEdit] = useState<EditState>(emptyEdit);
  const [newOpen, setNewOpen] = useState(false);
  const [draft, setDraft] = useState<EditState>(emptyEdit);

  const { data: warehouses, isLoading } = useQuery({
    queryKey: ['warehouses-admin', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Wh[]> => {
      const { data, error } = await supabase.from('warehouses')
        .select('id, code, name_ar, name_en, parent_id, is_active').order('code');
      if (error) throw error;
      return data as Wh[];
    },
  });

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['warehouses-admin', org?.id] });
    qc.invalidateQueries({ queryKey: ['warehouses'] });
  }

  function startEdit(w: Wh) {
    setEditId(w.id);
    setEdit({ code: w.code, name_ar: w.name_ar, name_en: w.name_en ?? '', parent_id: w.parent_id ?? '' });
  }

  async function saveEdit() {
    if (!editId) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('warehouses').update({
      code: edit.code.trim(), name_ar: edit.name_ar.trim(), name_en: edit.name_en.trim() || null,
      parent_id: edit.parent_id || null,
    }).eq('id', editId);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setEditId(null);
    invalidate();
  }

  async function addWarehouse() {
    if (!org || !draft.code.trim() || !draft.name_ar.trim()) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('warehouses').insert({
      org_id: org.id, code: draft.code.trim(), name_ar: draft.name_ar.trim(),
      name_en: draft.name_en.trim() || null, parent_id: draft.parent_id || null,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setDraft(emptyEdit);
    setNewOpen(false);
    invalidate();
  }

  async function toggleActive(w: Wh) {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('warehouses').update({ is_active: !w.is_active }).eq('id', w.id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    invalidate();
  }

  const ParentField = ({ value, onChange, excludeId }: { value: string; onChange: (v: string) => void; excludeId?: string }) => (
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">— بلا مستودع أب —</option>
      {warehouses?.filter((w) => w.id !== excludeId).map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
    </select>
  );

  return (
    <>
      <h1>المستودعات</h1>
      {err && <p className="error">{err}</p>}

      {!newOpen ? (
        <button onClick={() => setNewOpen(true)} style={{ marginBottom: '0.75rem' }}>+ مستودع جديد</button>
      ) : (
        <div className="card" style={{ marginBottom: '1rem' }}>
          <div className="row">
            <div className="field" style={{ width: 140 }}>
              <label>الرمز</label>
              <input value={draft.code} onChange={(e) => setDraft((s) => ({ ...s, code: e.target.value }))} dir="ltr" />
            </div>
            <div className="field grow">
              <label>الاسم</label>
              <input value={draft.name_ar} onChange={(e) => setDraft((s) => ({ ...s, name_ar: e.target.value }))} />
            </div>
            <div className="field grow">
              <label>مستودع أب (اختياري — لموقع فرعي داخل مستودع رئيسي)</label>
              <ParentField value={draft.parent_id} onChange={(v) => setDraft((s) => ({ ...s, parent_id: v }))} />
            </div>
          </div>
          <div className="row">
            <button className="btn-primary" disabled={busy || !draft.code.trim() || !draft.name_ar.trim()} onClick={addWarehouse}>حفظ</button>
            <button disabled={busy} onClick={() => { setNewOpen(false); setDraft(emptyEdit); }}>إلغاء</button>
          </div>
        </div>
      )}

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr><th>الرمز</th><th>الاسم</th><th>المستودع الأب</th><th>الحالة</th><th style={{ width: 200 }} /></tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {warehouses?.map((w) => editId === w.id ? (
              <tr key={w.id}>
                <td><input value={edit.code} onChange={(e) => setEdit((s) => ({ ...s, code: e.target.value }))} dir="ltr" /></td>
                <td><input value={edit.name_ar} onChange={(e) => setEdit((s) => ({ ...s, name_ar: e.target.value }))} /></td>
                <td><ParentField value={edit.parent_id} onChange={(v) => setEdit((s) => ({ ...s, parent_id: v }))} excludeId={w.id} /></td>
                <td className="muted">{w.is_active ? 'نشط' : 'موقوف'}</td>
                <td>
                  <div className="row">
                    <button className="btn-primary" disabled={busy} onClick={saveEdit}>حفظ</button>
                    <button disabled={busy} onClick={() => setEditId(null)}>إلغاء</button>
                  </div>
                </td>
              </tr>
            ) : (
              <tr key={w.id}>
                <td className="mono">{w.code}</td>
                <td>{w.name_ar}</td>
                <td className="muted">{warehouses.find((p) => p.id === w.parent_id)?.name_ar ?? '—'}</td>
                <td><span className={`badge ${w.is_active ? 'posted' : 'void'}`}>{w.is_active ? 'نشط' : 'موقوف'}</span></td>
                <td>
                  <div className="row">
                    <button disabled={busy} onClick={() => startEdit(w)}>تعديل</button>
                    <button disabled={busy} onClick={() => toggleActive(w)}>{w.is_active ? 'إيقاف' : 'تنشيط'}</button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
