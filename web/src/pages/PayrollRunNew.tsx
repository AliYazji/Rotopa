import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';

interface EmpOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }

interface Line {
  key: number; dealerId: string; salaryExpenseAccountId: string;
  basicSalary: string; transportationAmt: string; housingAmt: string; overtimeAmt: string; otherAdditions: string;
  taxAmt: string; loanAmount: string; discount: string; discount2: string; discount3: string; discountFood: string;
  notes: string;
}
let keySeq = 0;
const emptyLine = (): Line => ({
  key: keySeq++, dealerId: '', salaryExpenseAccountId: '',
  basicSalary: '', transportationAmt: '0', housingAmt: '0', overtimeAmt: '0', otherAdditions: '0',
  taxAmt: '0', loanAmount: '0', discount: '0', discount2: '0', discount3: '0', discountFood: '0', notes: '',
});
const num = (s: string) => parseFloat(s) || 0;
const gross = (l: Line) => num(l.basicSalary) + num(l.transportationAmt) + num(l.housingAmt) + num(l.overtimeAmt) + num(l.otherAdditions);
const deductions = (l: Line) => num(l.taxAmt) + num(l.loanAmount) + num(l.discount) + num(l.discount2) + num(l.discount3) + num(l.discountFood);
const net = (l: Line) => gross(l) - deductions(l);

export default function PayrollRunNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [runDate, setRunDate] = useState(today());
  const [description, setDescription] = useState('');
  const [paymentMethod, setPaymentMethod] = useState<'cash' | 'payable'>('payable');
  const [netAccountId, setNetAccountId] = useState('');
  const [defaultExpAccountId, setDefaultExpAccountId] = useState('');
  const [taxAccountId, setTaxAccountId] = useState('');
  const [loanAccountId, setLoanAccountId] = useState('');
  const [otherAccountId, setOtherAccountId] = useState('');
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

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

  const totals = useMemo(() => lines.reduce((s, l) => ({
    gross: s.gross + gross(l), deductions: s.deductions + deductions(l), net: s.net + net(l),
  }), { gross: 0, deductions: 0, net: 0 }), [lines]);

  function setLine(key: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function save() {
    setErr(null); setBusy(true);
    try {
      if (!netAccountId) throw new Error('اختر حساب صافي الرواتب');
      const valid = lines.filter((l) => l.dealerId && gross(l) > 0);
      if (valid.length === 0) throw new Error('أضف موظفاً واحداً على الأقل براتب');

      const { data: runId, error } = await supabase.rpc('create_payroll_run', {
        p_org: org!.id, p_run_date: runDate, p_description: description,
        p_lines: valid.map((l) => ({
          dealer_id: l.dealerId, salary_expense_account_id: l.salaryExpenseAccountId || null,
          basic_salary: num(l.basicSalary), transportation_amt: num(l.transportationAmt),
          housing_amt: num(l.housingAmt), overtime_amt: num(l.overtimeAmt), other_additions: num(l.otherAdditions),
          tax_amt: num(l.taxAmt), loan_amount: num(l.loanAmount), discount: num(l.discount),
          discount2: num(l.discount2), discount3: num(l.discount3), discount_food: num(l.discountFood),
          notes: l.notes,
        })),
        p_net_account_id: netAccountId, p_payment_method: paymentMethod,
        p_default_salary_expense_account_id: defaultExpAccountId || null,
        p_tax_payable_account_id: taxAccountId || null, p_loan_receivable_account_id: loanAccountId || null,
        p_other_deductions_account_id: otherAccountId || null,
      });
      if (error) throw error;

      const { error: pErr } = await supabase.rpc('post_payroll_run', { p_run_id: runId });
      if (pErr) throw pErr;
      nav('/payroll');
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <h1>كشف رواتب جديد</h1>
      <div className="card">
        <div className="row">
          <div className="field" style={{ width: 160 }}>
            <label>التاريخ</label>
            <input type="date" value={runDate} onChange={(e) => setRunDate(e.target.value)} />
          </div>
          <div className="field grow">
            <label>البيان</label>
            <input value={description} onChange={(e) => setDescription(e.target.value)} />
          </div>
        </div>

        <div className="row" style={{ alignItems: 'center' }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
            <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'payable'} onChange={() => setPaymentMethod('payable')} /> مستحقة (تُدفع لاحقاً)
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
            <input type="radio" style={{ width: 'auto' }} checked={paymentMethod === 'cash'} onChange={() => setPaymentMethod('cash')} /> مدفوعة نقداً فوراً
          </label>
        </div>
        <div className="field">
          <label>{paymentMethod === 'cash' ? 'حساب الصندوق/البنك المدفوع منه' : 'حساب رواتب مستحقة الدفع'}</label>
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
            <label>حساب ضريبة الدخل المستحقة (إن وُجدت استقطاعات)</label>
            <select value={taxAccountId} onChange={(e) => setTaxAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>حساب سلف الموظفين (إن وُجد استقطاع سلف)</label>
            <select value={loanAccountId} onChange={(e) => setLoanAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
          <div className="field grow">
            <label>حساب استقطاعات أخرى (إن وُجدت)</label>
            <select value={otherAccountId} onChange={(e) => setOtherAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
        </div>

        <h2 style={{ fontSize: '1rem', marginTop: '1rem' }}>الموظفون</h2>
        {lines.map((l) => (
          <div key={l.key} className="card" style={{ background: 'var(--surface-2)', marginBottom: '0.6rem' }}>
            <div className="row">
              <div className="field grow">
                <label>الموظف</label>
                <select value={l.dealerId} onChange={(e) => setLine(l.key, { dealerId: e.target.value })}>
                  <option value="">—</option>
                  {employees?.map((e) => <option key={e.id} value={e.id}>{e.name_ar}</option>)}
                </select>
              </div>
              <div className="field grow">
                <label>حساب المصروف (اختياري — يتجاوز الافتراضي)</label>
                <select value={l.salaryExpenseAccountId} onChange={(e) => setLine(l.key, { salaryExpenseAccountId: e.target.value })}>
                  <option value="">— الافتراضي —</option>
                  {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                </select>
              </div>
              <button type="button" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>
            </div>
            <div className="row" style={{ flexWrap: 'wrap' }}>
              <div className="field" style={{ width: 110 }}><label>الأساسي</label><input className="num" inputMode="decimal" value={l.basicSalary} onChange={(e) => setLine(l.key, { basicSalary: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>مواصلات</label><input className="num" inputMode="decimal" value={l.transportationAmt} onChange={(e) => setLine(l.key, { transportationAmt: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>سكن</label><input className="num" inputMode="decimal" value={l.housingAmt} onChange={(e) => setLine(l.key, { housingAmt: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>إضافي</label><input className="num" inputMode="decimal" value={l.overtimeAmt} onChange={(e) => setLine(l.key, { overtimeAmt: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>إضافات أخرى</label><input className="num" inputMode="decimal" value={l.otherAdditions} onChange={(e) => setLine(l.key, { otherAdditions: e.target.value })} /></div>
            </div>
            <div className="row" style={{ flexWrap: 'wrap' }}>
              <div className="field" style={{ width: 110 }}><label>ضريبة</label><input className="num" inputMode="decimal" value={l.taxAmt} onChange={(e) => setLine(l.key, { taxAmt: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>سلفة</label><input className="num" inputMode="decimal" value={l.loanAmount} onChange={(e) => setLine(l.key, { loanAmount: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>خصم 1</label><input className="num" inputMode="decimal" value={l.discount} onChange={(e) => setLine(l.key, { discount: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>خصم 2</label><input className="num" inputMode="decimal" value={l.discount2} onChange={(e) => setLine(l.key, { discount2: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>خصم 3</label><input className="num" inputMode="decimal" value={l.discount3} onChange={(e) => setLine(l.key, { discount3: e.target.value })} /></div>
              <div className="field" style={{ width: 110 }}><label>طعام</label><input className="num" inputMode="decimal" value={l.discountFood} onChange={(e) => setLine(l.key, { discountFood: e.target.value })} /></div>
            </div>
            <p className="muted" style={{ fontSize: '0.85rem', margin: 0 }}>صافي: <strong>{fmtMoney(net(l))}</strong></p>
          </div>
        ))}
        <button type="button" onClick={() => setLines((ls) => [...ls, emptyLine()])}>+ موظف</button>

        <div className="row" style={{ marginTop: '1rem', fontWeight: 700 }}>
          <span>الإجمالي: إضافات {fmtMoney(totals.gross)} — استقطاعات {fmtMoney(totals.deductions)} — صافي {fmtMoney(totals.net)}</span>
        </div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save} style={{ marginTop: '1rem' }}>حفظ وترحيل</button>
      </div>
    </>
  );
}
