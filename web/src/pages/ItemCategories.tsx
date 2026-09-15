import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface Cat {
  id: string; code: string; name_ar: string; name_en: string | null;
  sort_order: number; kitchen_station: string | null;
}

export default function ItemCategories() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editId, setEditId] = useState<string | null>(null);
  const [edit, setEdit] = useState<{ code: string; name_ar: string; name_en: string; sort_order: string; kitchen_station: string }>({
    code: '', name_ar: '', name_en: '', sort_order: '0', kitchen_station: '',
  });
  const [newCat, setNewCat] = useState({ code: '', name_ar: '' });

  const { data: cats, isLoading } = useQuery({
    queryKey: ['item-categories-admin', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Cat[]> => {
      const { data, error } = await supabase.from('item_categories')
        .select('id, code, name_ar, name_en, sort_order, kitchen_station').order('sort_order').order('code');
      if (error) throw error;
      return data as Cat[];
    },
  });

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['item-categories-admin', org?.id] });
    qc.invalidateQueries({ queryKey: ['item-categories'] });
  }

  function startEdit(c: Cat) {
    setEditId(c.id);
    setEdit({ code: c.code, name_ar: c.name_ar, name_en: c.name_en ?? '', sort_order: String(c.sort_order), kitchen_station: c.kitchen_station ?? '' });
  }

  async function saveEdit() {
    if (!editId) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('item_categories').update({
      code: edit.code.trim(), name_ar: edit.name_ar.trim(), name_en: edit.name_en.trim() || null,
      sort_order: parseInt(edit.sort_order, 10) || 0, kitchen_station: edit.kitchen_station.trim() || null,
    }).eq('id', editId);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setEditId(null);
    invalidate();
  }

  async function addCategory() {
    if (!org || !newCat.code.trim() || !newCat.name_ar.trim()) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('item_categories').insert({
      org_id: org.id, code: newCat.code.trim(), name_ar: newCat.name_ar.trim(),
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setNewCat({ code: '', name_ar: '' });
    invalidate();
  }

  async function remove(id: string) {
    if (!confirm('حذف هذه الفئة؟ سيُرفض الحذف إن كان لها أصناف مرتبطة بها.')) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('item_categories').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    invalidate();
  }

  return (
    <>
      <h1>فئات الأصناف</h1>
      {err && <p className="error">{err}</p>}

      <div className="card">
        <div className="row">
          <div className="field" style={{ width: 140 }}>
            <label>الرمز</label>
            <input value={newCat.code} onChange={(e) => setNewCat((s) => ({ ...s, code: e.target.value }))} dir="ltr" />
          </div>
          <div className="field grow">
            <label>الاسم</label>
            <input value={newCat.name_ar} onChange={(e) => setNewCat((s) => ({ ...s, name_ar: e.target.value }))} />
          </div>
          <button className="btn-primary" disabled={busy || !newCat.code.trim() || !newCat.name_ar.trim()} onClick={addCategory} style={{ alignSelf: 'flex-end' }}>
            + إضافة
          </button>
        </div>
      </div>

      <div className="card" style={{ marginTop: '1rem', padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr><th>الرمز</th><th>الاسم</th><th>الاسم الإنجليزي</th><th>ترتيب العرض</th><th>محطة المطبخ</th><th style={{ width: 160 }} /></tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {cats?.map((c) => editId === c.id ? (
              <tr key={c.id}>
                <td><input value={edit.code} onChange={(e) => setEdit((s) => ({ ...s, code: e.target.value }))} dir="ltr" /></td>
                <td><input value={edit.name_ar} onChange={(e) => setEdit((s) => ({ ...s, name_ar: e.target.value }))} /></td>
                <td><input value={edit.name_en} onChange={(e) => setEdit((s) => ({ ...s, name_en: e.target.value }))} dir="ltr" /></td>
                <td><input className="num" value={edit.sort_order} onChange={(e) => setEdit((s) => ({ ...s, sort_order: e.target.value }))} /></td>
                <td><input value={edit.kitchen_station} onChange={(e) => setEdit((s) => ({ ...s, kitchen_station: e.target.value }))} placeholder="اختياري" /></td>
                <td>
                  <div className="row">
                    <button className="btn-primary" disabled={busy} onClick={saveEdit}>حفظ</button>
                    <button disabled={busy} onClick={() => setEditId(null)}>إلغاء</button>
                  </div>
                </td>
              </tr>
            ) : (
              <tr key={c.id}>
                <td className="mono">{c.code}</td>
                <td>{c.name_ar}</td>
                <td className="muted">{c.name_en ?? '—'}</td>
                <td className="num">{c.sort_order}</td>
                <td className="muted">{c.kitchen_station ?? '—'}</td>
                <td>
                  <div className="row">
                    <button disabled={busy} onClick={() => startEdit(c)}>تعديل</button>
                    <button className="btn-danger" disabled={busy} onClick={() => remove(c.id)}>حذف</button>
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
