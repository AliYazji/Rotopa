import { Fragment, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, today, translateError } from '../lib/format.ts';

interface Row {
  category_id: string | null; category_code: string; category_name_ar: string; section: 'asset' | 'liability' | 'equity';
  category_sort: number; account_id: string | null; account_code: string | null; account_name_ar: string | null; amount: number;
}

function groupByCategory(rows: Row[]) {
  const order: string[] = [];
  const byCategory = new Map<string, { id: string; name: string; hasAccounts: boolean; rows: Row[] }>();
  for (const r of rows) {
    const key = r.category_id ?? r.category_code;
    if (!byCategory.has(key)) { byCategory.set(key, { id: key, name: r.category_name_ar, hasAccounts: !!r.account_id, rows: [] }); order.push(key); }
    byCategory.get(key)!.rows.push(r);
  }
  return order.map((id) => byCategory.get(id)!);
}

function Section({ title, groups, total }: { title: string; groups: { id: string; name: string; hasAccounts: boolean; rows: Row[] }[]; total: number }) {
  return (
    <>
      <tr style={{ fontWeight: 700, background: 'var(--surface-2)' }}><td colSpan={2}>{title}</td></tr>
      {groups.map((cat) => (
        <Fragment key={cat.id}>
          {cat.hasAccounts && <tr className="muted"><td>{cat.name}</td><td /></tr>}
          {cat.rows.map((r) => (
            <tr key={r.account_id ?? r.category_code}>
              <td style={{ paddingRight: r.account_id ? '1.5rem' : 0 }}>{r.account_id ? `${r.account_code} · ${r.account_name_ar}` : r.category_name_ar}</td>
              <td className="num">{fmtMoney(r.amount)}</td>
            </tr>
          ))}
        </Fragment>
      ))}
      {groups.length === 0 && <tr><td colSpan={2} className="muted">لا حسابات.</td></tr>}
      <tr style={{ fontWeight: 700 }}><td>إجمالي {title}</td><td className="num">{fmtMoney(total)}</td></tr>
    </>
  );
}

export default function BalanceSheet() {
  const { org } = useOrg();
  const [asOf, setAsOf] = useState(today());

  const { data, isLoading, error } = useQuery({
    queryKey: ['balance-sheet', org?.id, asOf],
    enabled: !!org,
    queryFn: async (): Promise<Row[]> => {
      const { data, error } = await supabase.rpc('balance_sheet', { p_org: org!.id, p_as_of: asOf });
      if (error) throw error;
      return data ?? [];
    },
  });

  // Accounts with a real balance but no category never show up above at
  // all (both report RPCs require a category to place an account) — the
  // migrated legacy data left most accounts unclassified (accountCategoryType
  // was only ever set on ~20% of them), so this is a real, common gap, not
  // an edge case. Surface it rather than leave a silently-wrong-looking
  // imbalance with no clue why.
  const { data: unclassifiedCount } = useQuery({
    queryKey: ['unclassified-with-balance', org?.id, asOf],
    enabled: !!org,
    queryFn: async (): Promise<number> => {
      const [{ data: tb, error: tbErr }, { data: accs, error: accErr }] = await Promise.all([
        supabase.rpc('trial_balance', { p_org: org!.id, p_as_of: asOf }),
        supabase.from('accounts').select('id, category_id').eq('org_id', org!.id),
      ]);
      if (tbErr) throw tbErr;
      if (accErr) throw accErr;
      const noCategory = new Set((accs ?? []).filter((a) => !a.category_id).map((a) => a.id));
      return (tb ?? []).filter((r: { account_id: string }) => noCategory.has(r.account_id)).length;
    },
  });

  const assets = useMemo(() => groupByCategory((data ?? []).filter((r) => r.section === 'asset')), [data]);
  const liabilities = useMemo(() => groupByCategory((data ?? []).filter((r) => r.section === 'liability')), [data]);
  const equity = useMemo(() => groupByCategory((data ?? []).filter((r) => r.section === 'equity')), [data]);
  const totalAssets = (data ?? []).filter((r) => r.section === 'asset').reduce((s, r) => s + Number(r.amount), 0);
  const totalLiabilities = (data ?? []).filter((r) => r.section === 'liability').reduce((s, r) => s + Number(r.amount), 0);
  const totalEquity = (data ?? []).filter((r) => r.section === 'equity').reduce((s, r) => s + Number(r.amount), 0);
  const balanced = Math.round(totalAssets * 100) === Math.round((totalLiabilities + totalEquity) * 100);

  return (
    <>
      <h1>الميزانية العمومية</h1>
      <div className="row" style={{ marginBottom: '1rem' }}>
        <div className="field" style={{ width: 160 }}>
          <label>حتى تاريخ</label>
          <input type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </div>
      </div>
      {error && <p className="error">{translateError((error as Error).message)}</p>}
      {isLoading && <p className="muted">جارٍ التحميل…</p>}
      {!!unclassifiedCount && (
        <div className="card" style={{ borderColor: 'var(--danger)', marginBottom: '1rem' }}>
          <p style={{ margin: 0 }}>
            {unclassifiedCount} حساب له رصيد لكن بلا تصنيف مالي — ما بيظهر هون ولا بقائمة
            الدخل. راجع <Link to="/accounts">دليل الحسابات</Link> وحدد "التصنيف" لكل حساب.
          </p>
        </div>
      )}

      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead><tr><th>البند</th><th className="num" style={{ width: 130 }}>المبلغ</th></tr></thead>
          <tbody>
            <Section title="الأصول" groups={assets} total={totalAssets} />
            <Section title="الالتزامات" groups={liabilities} total={totalLiabilities} />
            <Section title="حقوق الملكية" groups={equity} total={totalEquity} />
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700 }}>
              <td>الالتزامات + حقوق الملكية</td>
              <td className="num">{fmtMoney(totalLiabilities + totalEquity)}</td>
            </tr>
            <tr>
              <td colSpan={2} className={balanced ? 'muted' : 'error'} style={{ fontSize: '0.85rem' }}>
                {balanced ? 'متوازنة ✓' : `غير متوازنة — الفرق ${fmtMoney(Math.abs(totalAssets - totalLiabilities - totalEquity))}`}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
      <p className="muted" style={{ fontSize: '0.85rem', marginTop: '0.5rem' }}>
        "أرباح/خسائر غير مقفلة" ضمن حقوق الملكية = صافي الإيرادات والمصروفات منذ آخر إقفال — ما
        في إقفال دوري تلقائي بعد، فهاد السطر هو يلي بيخلّي الميزانية متوازنة.
      </p>
    </>
  );
}
