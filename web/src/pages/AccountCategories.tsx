import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface Cat {
  id: string; code: string; name_ar: string;
  statement: 'balance_sheet' | 'income_statement'; section: 'asset' | 'liability' | 'equity' | 'income' | 'expense';
  normal_balance: 'debit' | 'credit'; sort_order: number;
}

const STATEMENT_LABEL: Record<string, string> = { balance_sheet: 'الميزانية العمومية', income_statement: 'قائمة الدخل' };
const SECTION_LABEL: Record<string, string> = { asset: 'أصل', liability: 'خصم', equity: 'حقوق ملكية', income: 'إيراد', expense: 'مصروف' };
const BALANCE_LABEL: Record<string, string> = { debit: 'مدين', credit: 'دائن' };
const SECTIONS_BY_STATEMENT: Record<string, string[]> = {
  balance_sheet: ['asset', 'liability', 'equity'],
  income_statement: ['income', 'expense'],
};

type EditState = { code: string; name_ar: string; statement: string; section: string; normal_balance: string; sort_order: string };
const emptyEdit: EditState = { code: '', name_ar: '', statement: 'balance_sheet', section: 'asset', normal_balance: 'debit', sort_order: '0' };

export default function AccountCategories() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editId, setEditId] = useState<string | null>(null);
  const [edit, setEdit] = useState<EditState>(emptyEdit);
  const [newOpen, setNewOpen] = useState(false);
  const [draft, setDraft] = useState<EditState>(emptyEdit);

  const { data: cats, isLoading } = useQuery({
    queryKey: ['account-categories-admin', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Cat[]> => {
      const { data, error } = await supabase.from('account_categories')
        .select('id, code, name_ar, statement, section, normal_balance, sort_order').order('sort_order').order('code');
      if (error) throw error;
      return data as Cat[];
    },
  });

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['account-categories-admin', org?.id] });
    qc.invalidateQueries({ queryKey: ['account-categories'] });
  }

  function startEdit(c: Cat) {
    setEditId(c.id);
    setEdit({ code: c.code, name_ar: c.name_ar, statement: c.statement, section: c.section, normal_balance: c.normal_balance, sort_order: String(c.sort_order) });
  }

  async function saveEdit() {
    if (!editId) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('account_categories').update({
      code: edit.code.trim(), name_ar: edit.name_ar.trim(), statement: edit.statement, section: edit.section,
      normal_balance: edit.normal_balance, sort_order: parseInt(edit.sort_order, 10) || 0,
    }).eq('id', editId);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setEditId(null);
    invalidate();
  }

  async function addCategory() {
    if (!org || !draft.code.trim() || !draft.name_ar.trim()) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('account_categories').insert({
      org_id: org.id, code: draft.code.trim(), name_ar: draft.name_ar.trim(),
      statement: draft.statement, section: draft.section, normal_balance: draft.normal_balance,
      sort_order: parseInt(draft.sort_order, 10) || 0,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setDraft(emptyEdit);
    setNewOpen(false);
    invalidate();
  }

  async function remove(id: string) {
    if (!confirm('حذف هذا التصنيف؟ سيُرفض الحذف إن كان مرتبطاً بحسابات فعلية — وحذفه يغيّر تصنيف القوائم المالية.')) return;
    setErr(null); setBusy(true);
    const { error } = await supabase.from('account_categories').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    invalidate();
  }

  const StatementSectionFields = ({ value, onChange }: { value: EditState; onChange: (patch: Partial<EditState>) => void }) => (
    <>
      <select value={value.statement} onChange={(e) => onChange({ statement: e.target.value, section: SECTIONS_BY_STATEMENT[e.target.value]![0]! })}>
        <option value="balance_sheet">الميزانية العمومية</option>
        <option value="income_statement">قائمة الدخل</option>
      </select>
      <select value={value.section} onChange={(e) => onChange({ section: e.target.value })}>
        {SECTIONS_BY_STATEMENT[value.statement]!.map((s) => <option key={s} value={s}>{SECTION_LABEL[s]}</option>)}
      </select>
      <select value={value.normal_balance} onChange={(e) => onChange({ normal_balance: e.target.value })}>
        <option value="debit">مدين</option>
        <option value="credit">دائن</option>
      </select>
    </>
  );

  return (
    <>
      <h1>تصنيفات الحسابات</h1>
      <p className="muted" style={{ fontSize: '0.85rem' }}>
        هذه التصنيفات تحدد مكان ظهور كل حساب بقائمة الدخل والميزانية العمومية — تعديل قسم أو طبيعة
        تصنيف يُستخدَم فعلياً يغيّر تجميع التقارير المالية القائمة.
      </p>
      {err && <p className="error">{err}</p>}

      {!newOpen ? (
        <button onClick={() => setNewOpen(true)} style={{ marginBottom: '0.75rem' }}>+ تصنيف جديد</button>
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
          </div>
          <div className="row">
            <StatementSectionFields value={draft} onChange={(p) => setDraft((s) => ({ ...s, ...p }))} />
            <button className="btn-primary" disabled={busy || !draft.code.trim() || !draft.name_ar.trim()} onClick={addCategory}>حفظ</button>
            <button disabled={busy} onClick={() => { setNewOpen(false); setDraft(emptyEdit); }}>إلغاء</button>
          </div>
        </div>
      )}

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr><th>الرمز</th><th>الاسم</th><th>القائمة</th><th>القسم</th><th>الطبيعة</th><th style={{ width: 160 }} /></tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {cats?.map((c) => editId === c.id ? (
              <tr key={c.id}>
                <td><input value={edit.code} onChange={(e) => setEdit((s) => ({ ...s, code: e.target.value }))} dir="ltr" /></td>
                <td><input value={edit.name_ar} onChange={(e) => setEdit((s) => ({ ...s, name_ar: e.target.value }))} /></td>
                <td colSpan={3}><div className="row"><StatementSectionFields value={edit} onChange={(p) => setEdit((s) => ({ ...s, ...p }))} /></div></td>
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
                <td className="muted">{STATEMENT_LABEL[c.statement]}</td>
                <td className="muted">{SECTION_LABEL[c.section]}</td>
                <td className="muted">{BALANCE_LABEL[c.normal_balance]}</td>
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
