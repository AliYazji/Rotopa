import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';

interface Row {
  dealer_id: string; dealer_code: string; dealer_name: string;
  invoice_id: string; invoice_no: number; invoice_date: string; due_date: string;
  days_overdue: number; bucket: 'not_due' | '1_30' | '31_60' | '61_90' | 'over_90';
  invoice_total: number; open_amount: number;
}
const BUCKETS: Row['bucket'][] = ['not_due', '1_30', '31_60', '61_90', 'over_90'];
const BUCKET_LABEL: Record<Row['bucket'], string> = {
  not_due: 'غير مستحق بعد', '1_30': '1-30 يوم', '31_60': '31-60 يوم', '61_90': '61-90 يوم', over_90: 'أكثر من 90 يوم',
};

function groupByDealer(rows: Row[]) {
  const order: string[] = [];
  const byDealer = new Map<string, { id: string; code: string; name: string; rows: Row[] }>();
  for (const r of rows) {
    if (!byDealer.has(r.dealer_id)) { byDealer.set(r.dealer_id, { id: r.dealer_id, code: r.dealer_code, name: r.dealer_name, rows: [] }); order.push(r.dealer_id); }
    byDealer.get(r.dealer_id)!.rows.push(r);
  }
  return order.map((id) => byDealer.get(id)!);
}

export default function ArAging({
  title = 'أعمار ديون العملاء', rpc = 'ar_aging_detail', dealerLabel = 'العميل',
}: { title?: string; rpc?: string; dealerLabel?: string }) {
  const { org } = useOrg();
  const [asOf, setAsOf] = useState(today());

  const { data, isLoading, error } = useQuery({
    queryKey: [rpc, org?.id, asOf],
    enabled: !!org,
    queryFn: async (): Promise<Row[]> => {
      const { data, error } = await supabase.rpc(rpc, { p_org: org!.id, p_as_of: asOf });
      if (error) throw error;
      return (data ?? []) as Row[];
    },
  });

  const dealers = useMemo(() => groupByDealer(data ?? []), [data]);
  const bucketTotals = useMemo(() => {
    const t = { not_due: 0, '1_30': 0, '31_60': 0, '61_90': 0, over_90: 0 } satisfies Record<Row['bucket'], number>;
    for (const r of data ?? []) t[r.bucket] += Number(r.open_amount);
    return t;
  }, [data]);
  const grandTotal = BUCKETS.reduce((s, b) => s + bucketTotals[b], 0);

  return (
    <>
      <h1>{title}</h1>
      <p className="muted">
        كل مبلغ مفتوح مبني على افتراض قياسي: التحصيلات تُطبَّق على أقدم فاتورة أولاً (FIFO) — النظام
        لا يربط سنداً بفاتورة معيّنة. مجموع كل الأعمدة لكل {dealerLabel} يطابق دايماً رصيده الفعلي بدفتر الأستاذ.
      </p>
      <div className="row" style={{ marginBottom: '1rem' }}>
        <div className="field" style={{ width: 160 }}>
          <label>كما في تاريخ</label>
          <input type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        </div>
      </div>
      {error && <p className="error">{translateError((error as Error).message)}</p>}
      {isLoading && <p className="muted">جارٍ التحميل…</p>}

      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1.5rem' }}>
        <table>
          <thead>
            <tr>
              <th>{dealerLabel}</th>
              {BUCKETS.map((b) => <th key={b} className="num" style={{ width: 110 }}>{BUCKET_LABEL[b]}</th>)}
              <th className="num" style={{ width: 120 }}>الإجمالي</th>
            </tr>
          </thead>
          <tbody>
            {dealers.map((d) => {
              const totals = { not_due: 0, '1_30': 0, '31_60': 0, '61_90': 0, over_90: 0 } satisfies Record<Row['bucket'], number>;
              for (const r of d.rows) totals[r.bucket] += Number(r.open_amount);
              const dealerTotal = BUCKETS.reduce((s, b) => s + totals[b], 0);
              return (
                <tr key={d.id}>
                  <td>{d.code} · {d.name}</td>
                  {BUCKETS.map((b) => (
                    <td key={b} className="num" style={b === 'over_90' && totals[b] > 0 ? { color: 'var(--danger)' } : undefined}>
                      {totals[b] > 0 ? fmtMoney(totals[b]) : '—'}
                    </td>
                  ))}
                  <td className="num" style={{ fontWeight: 600 }}>{fmtMoney(dealerTotal)}</td>
                </tr>
              );
            })}
            {dealers.length === 0 && !isLoading && (
              <tr><td colSpan={BUCKETS.length + 2} className="muted">لا ديون مفتوحة بهذا التاريخ.</td></tr>
            )}
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700 }}>
              <td>الإجمالي</td>
              {BUCKETS.map((b) => <td key={b} className="num">{fmtMoney(bucketTotals[b])}</td>)}
              <td className="num">{fmtMoney(grandTotal)}</td>
            </tr>
          </tfoot>
        </table>
      </div>

      <h2 style={{ fontSize: '0.95rem' }}>تفصيل الفواتير المفتوحة</h2>
      <div className="card" style={{ padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th>{dealerLabel}</th>
              <th style={{ width: 70 }}>#</th>
              <th style={{ width: 100 }}>تاريخ الفاتورة</th>
              <th style={{ width: 100 }}>الاستحقاق</th>
              <th style={{ width: 90 }}>الفئة</th>
              <th className="num" style={{ width: 100 }}>إجمالي الفاتورة</th>
              <th className="num" style={{ width: 100 }}>المبلغ المفتوح</th>
            </tr>
          </thead>
          <tbody>
            {(data ?? []).map((r) => (
              <tr key={r.invoice_id}>
                <td>{r.dealer_name}</td>
                <td className="mono">{r.invoice_no}</td>
                <td>{fmtDate(r.invoice_date)}</td>
                <td>{fmtDate(r.due_date)}</td>
                <td className={r.bucket === 'over_90' || r.bucket === '61_90' ? 'error' : undefined}>{BUCKET_LABEL[r.bucket]}</td>
                <td className="num">{fmtMoney(r.invoice_total)}</td>
                <td className="num">{fmtMoney(r.open_amount)}</td>
              </tr>
            ))}
            {(data ?? []).length === 0 && !isLoading && (
              <tr><td colSpan={7} className="muted">لا فواتير مفتوحة بهذا التاريخ.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
