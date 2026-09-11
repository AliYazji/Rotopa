import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Run {
  id: string; run_no: number; run_date: string; description: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'cash' | 'payable'; net_account_id: string; default_salary_expense_account_id: string | null;
  tax_payable_account_id: string | null; loan_receivable_account_id: string | null; other_deductions_account_id: string | null;
  void_reason: string | null;
}
interface Line {
  id: string; line_no: number; dealer_id: string; salary_expense_account_id: string | null;
  basic_salary: number; transportation_amt: number; housing_amt: number; overtime_amt: number; other_additions: number;
  tax_amt: number; loan_amount: number; discount: number; discount2: number; discount3: number; discount_food: number;
  gross: number; deductions: number; net_salary: number; notes: string;
  dealer: { name_ar: string } | null;
}
interface EmpOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }

interface EditLine {
  key: number; dealerId: string; dealerLabel: string; salaryExpenseAccountId: string;
  basicSalary: string; transportationAmt: string; housingAmt: string; overtimeAmt: string; otherAdditions: string;
  taxAmt: string; loanAmount: string; discount: string; discount2: string; discount3: string; discountFood: string;
  notes: string;
}
let keySeq = 0;
const toEditLine = (l: Line): EditLine => ({
  key: keySeq++, dealerId: l.dealer_id, dealerLabel: l.dealer?.name_ar ?? '', salaryExpenseAccountId: l.salary_expense_account_id ?? '',
  basicSalary: String(l.basic_salary), transportationAmt: String(l.transportation_amt), housingAmt: String(l.housing_amt),
  overtimeAmt: String(l.overtime_amt), otherAdditions: String(l.other_additions),
  taxAmt: String(l.tax_amt), loanAmount: String(l.loan_amount), discount: String(l.discount),
  discount2: String(l.discount2), discount3: String(l.discount3), discountFood: String(l.discount_food),
  notes: l.notes,
});
const num = (s: string) => parseFloat(s) || 0;
const editGross = (l: EditLine) => num(l.basicSalary) + num(l.transportationAmt) + num(l.housingAmt) + num(l.overtimeAmt) + num(l.otherAdditions);
const editDeductions = (l: EditLine) => num(l.taxAmt) + num(l.loanAmount) + num(l.discount) + num(l.discount2) + num(l.discount3) + num(l.discountFood);
const editNet = (l: EditLine) => editGross(l) - editDeductions(l);

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function PayrollRunDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);

  const [description, setDescription] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<'cash' | 'payable'>('payable');
  const [netAccountId, setNetAccountId] = useState('');
  const [defaultExpAccountId, setDefaultExpAccountId] = useState('');
  const [taxAccountId, setTaxAccountId] = useState('');
  const [loanAccountId, setLoanAccountId] = useState('');
  const [otherAccountId, setOtherAccountId] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: run, isLoading } = useQuery({
    queryKey: ['payroll-run', id], enabled: !!id,
    queryFn: async (): Promise<Run> => {
      const { data, error } = await supabase.from('payroll_runs')
        .select('id, run_no, run_date, description, status, payment_method, net_account_id, default_salary_expense_account_id, tax_payable_account_id, loan_receivable_account_id, other_deductions_account_id, void_reason')
        .eq('id', id).single();
      if (error) throw error; return data as Run;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['payroll-run-lines', id], enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('payroll_run_lines')
        .select('id, line_no, dealer_id, salary_expense_account_id, basic_salary, transportation_amt, housing_amt, overtime_amt, other_additions, tax_amt, loan_amount, discount, discount2, discount3, discount_food, gross, deductions, net_salary, notes, dealer:dealer_id(name_ar)')
        .eq('run_id', id).order('line_no');
      if (error) throw error; return data as unknown as Line[];
    },
  });
  const { data: employees } = useQuery({
    queryKey: ['employees-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<EmpOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').eq('is_employee', true).order('name_ar').limit(500);
      if (error) throw error; return data as EmpOpt[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  useEffect(() => {
    if (run) {
      setDescription(run.description ?? ''); setPaymentMethod(run.payment_method); setNetAccountId(run.net_account_id);
      setDefaultExpAccountId(run.default_salary_expense_account_id ?? ''); setTaxAccountId(run.tax_payable_account_id ?? '');
      setLoanAccountId(run.loan_receivable_account_id ?? ''); setOtherAccountId(run.other_deductions_account_id ?? '');
    }
  }, [run]);
  useEffect(() => { if (lines) setEditLines(lines.map(toEditLine)); }, [lines]);

  function setEditLine(key: number, patch: Partial<EditLine>) {
    setEditLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }
  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['payroll-run', id] });
    await qc.invalidateQueries({ queryKey: ['payroll-run-lines', id] });
    await qc.invalidateQueries({ queryKey: ['payroll-runs'] });
  }

  async function saveDraft() {
    setErr(null); setBusy(true);
    try {
      if (!netAccountId) throw new Error('اختر حساب صافي الرواتب');
      const valid = editLines.filter((l) => l.dealerId && editGross(l) > 0);
      if (valid.length === 0) throw new Error('أضف موظفاً واحداً على الأقل براتب');

      const { error: uErr } = await supabase.from('payroll_runs').update({
        description, payment_method: paymentMethod, net_account_id: netAccountId,
        default_salary_expense_account_id: defaultExpAccountId || null,
        tax_payable_account_id: taxAccountId || null, loan_receivable_account_id: loanAccountId || null,
        other_deductions_account_id: otherAccountId || null,
      }).eq('id', id);
      if (uErr) throw uErr;

      const { error: dErr } = await supabase.from('payroll_run_lines').delete().eq('run_id', id);
      if (dErr) throw dErr;
      const { error: iErr } = await supabase.from('payroll_run_lines').insert(
        valid.map((l, i) => ({
          run_id: id, line_no: i + 1, dealer_id: l.dealerId, salary_expense_account_id: l.salaryExpenseAccountId || null,
          basic_salary: num(l.basicSalary), transportation_amt: num(l.transportationAmt), housing_amt: num(l.housingAmt),
          overtime_amt: num(l.overtimeAmt), other_additions: num(l.otherAdditions),
          tax_amt: num(l.taxAmt), loan_amount: num(l.loanAmount), discount: num(l.discount),
          discount2: num(l.discount2), discount3: num(l.discount3), discount_food: num(l.discountFood),
          notes: l.notes,
        })),
      );
      if (iErr) throw iErr;
      setEditing(false);
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function postDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_payroll_run', { p_run_id: id });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('payroll_runs').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/payroll');
  }
  async function voidRun() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('void_payroll_run', { p_run_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function duplicateToDraft() {
    if (!run || !lines) return;
    setErr(null); setBusy(true);
    try {
      const { data: newId, error } = await supabase.rpc('create_payroll_run', {
        p_org: org!.id, p_run_date: today(),
        p_description: run.description ? `نسخة عن كشف رقم ${run.run_no} — ${run.description}` : `نسخة عن كشف رقم ${run.run_no}`,
        p_lines: lines.map((l) => ({
          dealer_id: l.dealer_id, salary_expense_account_id: l.salary_expense_account_id,
          basic_salary: l.basic_salary, transportation_amt: l.transportation_amt, housing_amt: l.housing_amt,
          overtime_amt: l.overtime_amt, other_additions: l.other_additions,
          tax_amt: l.tax_amt, loan_amount: l.loan_amount, discount: l.discount, discount2: l.discount2,
          discount3: l.discount3, discount_food: l.discount_food, notes: l.notes,
        })),
        p_net_account_id: run.net_account_id, p_payment_method: run.payment_method,
        p_default_salary_expense_account_id: run.default_salary_expense_account_id,
        p_tax_payable_account_id: run.tax_payable_account_id, p_loan_receivable_account_id: run.loan_receivable_account_id,
        p_other_deductions_account_id: run.other_deductions_account_id,
      });
      if (error) throw error;
      nav(`/payroll/${newId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  if (isLoading || !run) return <p className="muted">جارٍ التحميل…</p>;
  const totals = (editing ? editLines.map((l) => ({ gross: editGross(l), deductions: editDeductions(l), net: editNet(l) }))
    : (lines ?? []).map((l) => ({ gross: Number(l.gross), deductions: Number(l.deductions), net: Number(l.net_salary) })))
    .reduce((s, x) => ({ gross: s.gross + x.gross, deductions: s.deductions + x.deductions, net: s.net + x.net }), { gross: 0, deductions: 0, net: 0 });

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>كشف رواتب رقم {run.run_no}</h1>
        <span className={`badge ${run.status}`}>{STATUS[run.status]}</span>
      </div>
      <p className="muted">{fmtDate(run.run_date)} · {run.payment_method === 'cash' ? 'مدفوع نقداً' : 'مستحق الدفع'}</p>

      {run.status === 'draft' && editing ? (
        <div className="card">
          <div className="field"><label>البيان</label><input value={description} onChange={(e) => setDescription(e.target.value)} /></div>
          <div className="row" style={{ alignItems: 'center' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'payable'} onChange={() => setPaymentMethod('payable')} /> مستحقة
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'cash'} onChange={() => setPaymentMethod('cash')} /> نقداً فوراً
            </label>
          </div>
          <div className="field">
            <label>{paymentMethod === 'cash' ? 'حساب الصندوق/البنك' : 'حساب رواتب مستحقة الدفع'}</label>
            <select value={netAccountId} onChange={(e) => setNetAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
          <div className="row">
            <div className="field grow">
              <label>حساب مصروف الرواتب الافتراضي</label>
              <select value={defaultExpAccountId} onChange={(e) => setDefaultExpAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
            <div className="field grow">
              <label>حساب ضريبة الدخل</label>
              <select value={taxAccountId} onChange={(e) => setTaxAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          </div>
          <div className="row">
            <div className="field grow">
              <label>حساب سلف الموظفين</label>
              <select value={loanAccountId} onChange={(e) => setLoanAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
            <div className="field grow">
              <label>حساب استقطاعات أخرى</label>
              <select value={otherAccountId} onChange={(e) => setOtherAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          </div>

          <h2 style={{ fontSize: '1rem', marginTop: '1rem' }}>الموظفون</h2>
          {editLines.map((l) => (
            <div key={l.key} className="card" style={{ background: 'var(--surface-2)', marginBottom: '0.6rem' }}>
              <div className="row">
                <div className="field grow">
                  <label>الموظف</label>
                  <select value={l.dealerId} onChange={(e) => setEditLine(l.key, { dealerId: e.target.value })}>
                    <option value="">—</option>
                    {employees?.map((e) => <option key={e.id} value={e.id}>{e.name_ar}</option>)}
                  </select>
                </div>
                <div className="field grow">
                  <label>حساب المصروف (اختياري)</label>
                  <select value={l.salaryExpenseAccountId} onChange={(e) => setEditLine(l.key, { salaryExpenseAccountId: e.target.value })}>
                    <option value="">— الافتراضي —</option>
                    {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                  </select>
                </div>
                <button type="button" onClick={() => setEditLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>
              </div>
              <div className="row" style={{ flexWrap: 'wrap' }}>
                <div className="field" style={{ width: 110 }}><label>الأساسي</label><input className="num" inputMode="decimal" value={l.basicSalary} onChange={(e) => setEditLine(l.key, { basicSalary: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>مواصلات</label><input className="num" inputMode="decimal" value={l.transportationAmt} onChange={(e) => setEditLine(l.key, { transportationAmt: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>سكن</label><input className="num" inputMode="decimal" value={l.housingAmt} onChange={(e) => setEditLine(l.key, { housingAmt: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>إضافي</label><input className="num" inputMode="decimal" value={l.overtimeAmt} onChange={(e) => setEditLine(l.key, { overtimeAmt: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>إضافات أخرى</label><input className="num" inputMode="decimal" value={l.otherAdditions} onChange={(e) => setEditLine(l.key, { otherAdditions: e.target.value })} /></div>
              </div>
              <div className="row" style={{ flexWrap: 'wrap' }}>
                <div className="field" style={{ width: 110 }}><label>ضريبة</label><input className="num" inputMode="decimal" value={l.taxAmt} onChange={(e) => setEditLine(l.key, { taxAmt: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>سلفة</label><input className="num" inputMode="decimal" value={l.loanAmount} onChange={(e) => setEditLine(l.key, { loanAmount: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>خصم 1</label><input className="num" inputMode="decimal" value={l.discount} onChange={(e) => setEditLine(l.key, { discount: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>خصم 2</label><input className="num" inputMode="decimal" value={l.discount2} onChange={(e) => setEditLine(l.key, { discount2: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>خصم 3</label><input className="num" inputMode="decimal" value={l.discount3} onChange={(e) => setEditLine(l.key, { discount3: e.target.value })} /></div>
                <div className="field" style={{ width: 110 }}><label>طعام</label><input className="num" inputMode="decimal" value={l.discountFood} onChange={(e) => setEditLine(l.key, { discountFood: e.target.value })} /></div>
              </div>
              <p className="muted" style={{ fontSize: '0.85rem', margin: 0 }}>صافي: <strong>{fmtMoney(editNet(l))}</strong></p>
            </div>
          ))}
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, dealerId: '', dealerLabel: '', salaryExpenseAccountId: '', basicSalary: '', transportationAmt: '0', housingAmt: '0', overtimeAmt: '0', otherAdditions: '0', taxAmt: '0', loanAmount: '0', discount: '0', discount2: '0', discount3: '0', discountFood: '0', notes: '' }])}>+ موظف</button>

          {err && <p className="error">{err}</p>}
          <div className="row" style={{ marginTop: '1rem' }}>
            <button className="btn-primary" disabled={busy} onClick={saveDraft}>حفظ التعديلات</button>
            <button disabled={busy} onClick={() => { setEditing(false); setErr(null); if (lines) setEditLines(lines.map(toEditLine)); }}>إلغاء</button>
          </div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
          <table>
            <thead>
              <tr>
                <th>الموظف</th>
                <th className="num" style={{ width: 100 }}>الإضافات</th>
                <th className="num" style={{ width: 100 }}>الاستقطاعات</th>
                <th className="num" style={{ width: 100 }}>الصافي</th>
              </tr>
            </thead>
            <tbody>
              {lines?.map((l) => (
                <tr key={l.id}>
                  <td>{l.dealer?.name_ar}</td>
                  <td className="num">{fmtMoney(l.gross)}</td>
                  <td className="num">{fmtMoney(l.deductions)}</td>
                  <td className="num">{fmtMoney(l.net_salary)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td>الإجمالي</td><td className="num">{fmtMoney(totals.gross)}</td><td className="num">{fmtMoney(totals.deductions)}</td><td className="num">{fmtMoney(totals.net)}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      {run.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 460 }}>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postDraft}>ترحيل</button>
            <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}
      {run.status === 'posted' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء الكشف</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>بينشئ قيداً عكسياً — الكشف الأصلي بيضل موجود وثابت.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-danger" disabled={busy} onClick={voidRun}>إلغاء الكشف</button>
            <button disabled={busy} onClick={duplicateToDraft}>نسخ لمسودة جديدة</button>
          </div>
        </div>
      )}
      {run.status === 'void' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <p className="muted">أُلغي{run.void_reason ? ` — ${run.void_reason}` : ''}.</p>
          {err && <p className="error">{err}</p>}
          <button disabled={busy} onClick={duplicateToDraft}>نسخ لمسودة جديدة</button>
        </div>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/payroll">‹ رجوع لقائمة كشوف الرواتب</Link></p>
    </>
  );
}
