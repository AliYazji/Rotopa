import { Fragment, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';

interface Row {
  category_id: string; category_code: string; category_name_ar: string; section: 'income' | 'expense';
  category_sort: number; account_id: string; account_code: string; account_name_ar: string; amount: number;
}

function yearStart() {
  return `${new Date().getFullYear()}-01-01`;
}

function groupByCategory(rows: Row[]) {
  const order: string[] = [];
  const byCategory = new Map<string, { id: string; name: string; rows: Row[] }>();
  for (const r of rows) {
    if (!byCategory.has(r.category_id)) { byCategory.set(r.category_id, { id: r.category_id, name: r.category_name_ar, rows: [] }); order.push(r.category_id); }
    byCategory.get(r.category_id)!.rows.push(r);
  }
  return order.map((id) => byCategory.get(id)!);
}

export default function IncomeStatement() {
  const { org } = useOrg();
  const [from, setFrom] = useState(yearStart());
  const [to, setTo] = useState(today());

  const { data, isLoading, error } = useQuery({
    queryKey: ['income-statement', org?.id, from, to],
    enabled: !!org,
    queryFn: async (): Promise<Row[]> => {
      const { data, error } = await supabase.rpc('income_statement', { p_org: org!.id, p_from: from, p_to: to });
      if (error) throw error;
      return data ?? [];
    },
  });

  // Accounts with a real balance but no category never show up on either
  // financial statement (both RPCs require one to place an account) — the
  // migrated legacy data left most accounts unclassified (accountCategoryType
  // was only ever set on ~20% of them), so this is a common gap, not an
  // edge case. Surface it rather than leave "no expenses this period" for
  // an org that clearly has expense activity, with no clue why.
  const { data: unclassifiedCount } = useQuery({
    queryKey: ['unclassified-with-balance', org?.id, to],
    enabled: !!org,
    queryFn: async (): Promise<number> => {
      const [{ data: tb, error: tbErr }, { data: accs, error: accErr }] = await Promise.all([
        supabase.rpc('trial_balance', { p_org: org!.id, p_as_of: to }),
        supabase.from('accounts').select('id, category_id').eq('org_id', org!.id),
      ]);
      if (tbErr) throw tbErr;
      if (accErr) throw accErr;
      const noCategory = new Set((accs ?? []).filter((a) => !a.category_id).map((a) => a.id));
      return (tb ?? []).filter((r: { account_id: string }) => noCategory.has(r.account_id)).length;
    },
  });

  const income = useMemo(() => groupByCategory((data ?? []).filter((r) => r.section === 'income')), [data]);
  const expense = useMemo(() => groupByCategory((data ?? []).filter((r) => r.section === 'expense')), [data]);
  const totalIncome = (data ?? []).filter((r) => r.section === 'income').reduce((s, r) => s + Number(r.amount), 0);
  const totalExpense = (data ?? []).filter((r) => r.section === 'expense').reduce((s, r) => s + Number(r.amount), 0);
  const net = totalIncome - totalExpense;

  return (
    <>
      <h1>قائمة الدخل</h1>
      <div className="row" style={{ marginBottom: '1rem' }}>
        <div className="field" style={{ width: 160 }}>
          <label>من تاريخ</label>
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </div>
        <div className="field" style={{ width: 160 }}>
          <label>إلى تاريخ</label>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
      </div>
      {error && <p className="error">{translateError((error as Error).message)}</p>}
      {isLoading && <p className="muted">جارٍ التحميل…</p>}
      {!!unclassifiedCount && (
        <div className="card" style={{ borderColor: 'var(--danger)', marginBottom: '1rem' }}>
          <p style={{ margin: 0 }}>
            {unclassifiedCount} حساب له رصيد لكن بلا تصنيف مالي — ما بيظهر هون ولا بالميزانية
            العمومية. راجع <Link to="/accounts">دليل الحسابات</Link> وحدد "التصنيف" لكل حساب.
          </p>
        </div>
      )}

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead><tr><th>البند</th><th className="num" style={{ width: 130 }}>المبلغ</th></tr></thead>
          <tbody>
            <tr style={{ fontWeight: 700, background: 'var(--surface-2)' }}><td colSpan={2}>الإيرادات</td></tr>
            {income.map((cat) => (
              <Fragment key={cat.id}>
                <tr className="muted"><td>{cat.name}</td><td /></tr>
                {cat.rows.map((r) => (
                  <tr key={r.account_id}><td style={{ paddingRight: '1.5rem' }}>{r.account_code} · {r.account_name_ar}</td><td className="num">{fmtMoney(r.amount)}</td></tr>
                ))}
              </Fragment>
            ))}
            {income.length === 0 && !isLoading && <tr><td colSpan={2} className="muted">لا إيرادات بهذه الفترة.</td></tr>}
            <tr style={{ fontWeight: 700 }}><td>إجمالي الإيرادات</td><td className="num">{fmtMoney(totalIncome)}</td></tr>

            <tr style={{ fontWeight: 700, background: 'var(--surface-2)' }}><td colSpan={2}>المصروفات</td></tr>
            {expense.map((cat) => (
              <Fragment key={cat.id}>
                <tr className="muted"><td>{cat.name}</td><td /></tr>
                {cat.rows.map((r) => (
                  <tr key={r.account_id}><td style={{ paddingRight: '1.5rem' }}>{r.account_code} · {r.account_name_ar}</td><td className="num">{fmtMoney(r.amount)}</td></tr>
                ))}
              </Fragment>
            ))}
            {expense.length === 0 && !isLoading && <tr><td colSpan={2} className="muted">لا مصروفات بهذه الفترة.</td></tr>}
            <tr style={{ fontWeight: 700 }}><td>إجمالي المصروفات</td><td className="num">{fmtMoney(totalExpense)}</td></tr>
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700, fontSize: '1.05rem' }}>
              <td>{net >= 0 ? 'صافي الربح' : 'صافي الخسارة'}</td>
              <td className="num" style={{ color: net >= 0 ? 'var(--credit)' : 'var(--danger)' }}>{fmtMoney(Math.abs(net))}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </>
  );
}
