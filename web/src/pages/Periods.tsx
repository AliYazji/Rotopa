import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, translateError } from '../lib/format.ts';

interface Year { id: string; code: string; start_date: string; end_date: string; status: 'open' | 'closed'; }
interface Period {
  id: string; fiscal_year_id: string; period_no: number; start_date: string; end_date: string;
  status: 'open' | 'closed' | 'locked'; closed_at: string | null;
}
interface ClosureLogRow {
  id: number; fiscal_year_code: string; period_no: number | null; action: 'close' | 'reopen';
  reason: string | null; done_by_email: string | null; done_at: string;
}

export default function Periods() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reopenTarget, setReopenTarget] = useState<{ kind: 'period' | 'year'; id: string } | null>(null);
  const [reopenReason, setReopenReason] = useState('');

  const { data: years } = useQuery({
    queryKey: ['fiscal-years', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Year[]> => {
      const { data, error } = await supabase.from('fiscal_years').select('id, code, start_date, end_date, status').order('start_date');
      if (error) throw error;
      return data as Year[];
    },
  });

  const { data: periods } = useQuery({
    queryKey: ['fiscal-periods', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Period[]> => {
      const { data, error } = await supabase.from('fiscal_periods')
        .select('id, fiscal_year_id, period_no, start_date, end_date, status, closed_at').order('start_date');
      if (error) throw error;
      return data as Period[];
    },
  });

  const { data: log } = useQuery({
    queryKey: ['period-closure-log', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<ClosureLogRow[]> => {
      const { data, error } = await supabase.rpc('fiscal_period_closure_log', { p_org: org!.id });
      if (error) throw error;
      return data as ClosureLogRow[];
    },
  });

  // closed periods always form a contiguous prefix of chronological order (the
  // close/reopen guards enforce this) — so only the first open one can close
  // next, and only the last closed one can reopen next.
  const nextCloseId = useMemo(() => periods?.find((p) => p.status === 'open')?.id ?? null, [periods]);
  const nextReopenId = useMemo(() => [...(periods ?? [])].reverse().find((p) => p.status === 'closed')?.id ?? null, [periods]);

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['fiscal-years', org?.id] });
    qc.invalidateQueries({ queryKey: ['fiscal-periods', org?.id] });
    qc.invalidateQueries({ queryKey: ['period-closure-log', org?.id] });
  }

  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>) {
    setErr(null); setBusy(true);
    try {
      const { error } = await fn();
      if (error) throw new Error(error.message);
      invalidate();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  async function submitReopen() {
    if (!reopenTarget || !reopenReason.trim()) return;
    const { kind, id } = reopenTarget;
    await run(() =>
      kind === 'period'
        ? supabase.rpc('reopen_fiscal_period', { p_period_id: id, p_reason: reopenReason.trim() })
        : supabase.rpc('reopen_fiscal_year', { p_fiscal_year_id: id, p_reason: reopenReason.trim() }),
    );
    setReopenTarget(null);
    setReopenReason('');
  }

  const monthName = (n: number) =>
    ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'][n - 1] ?? String(n);

  return (
    <>
      <h1>الفترات المحاسبية</h1>
      {err && <p className="error">{err}</p>}

      {years?.map((y) => {
        const yearPeriods = periods?.filter((p) => p.fiscal_year_id === y.id) ?? [];
        const allClosed = yearPeriods.length > 0 && yearPeriods.every((p) => p.status === 'closed');
        return (
          <div className="card" key={y.id} style={{ marginBottom: '1rem' }}>
            <div className="row" style={{ justifyContent: 'space-between' }}>
              <h2>السنة المالية {y.code}</h2>
              <div className="row">
                <span className={`badge ${y.status === 'open' ? 'posted' : 'void'}`}>{y.status === 'open' ? 'مفتوحة' : 'مقفلة'}</span>
                {y.status === 'open' && (
                  <button
                    disabled={busy || !allClosed}
                    title={!allClosed ? 'يجب إقفال كل فترات السنة أولاً' : ''}
                    onClick={() => run(() => supabase.rpc('close_fiscal_year', { p_fiscal_year_id: y.id }))}
                  >
                    إقفال السنة المالية
                  </button>
                )}
                {y.status === 'closed' && (
                  <button disabled={busy} onClick={() => { setReopenTarget({ kind: 'year', id: y.id }); setReopenReason(''); }}>
                    إعادة فتح السنة
                  </button>
                )}
              </div>
            </div>

            {reopenTarget?.kind === 'year' && reopenTarget.id === y.id && (
              <div className="row" style={{ marginTop: '0.5rem' }}>
                <input className="grow" placeholder="سبب إعادة الفتح (إلزامي)" value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} />
                <button className="btn-primary" disabled={busy || !reopenReason.trim()} onClick={submitReopen}>تأكيد</button>
                <button disabled={busy} onClick={() => setReopenTarget(null)}>إلغاء</button>
              </div>
            )}

            <div style={{ overflowX: 'auto', marginTop: '0.75rem' }}>
              <table>
                <thead>
                  <tr><th>الفترة</th><th>من</th><th>إلى</th><th>الحالة</th><th style={{ width: 260 }} /></tr>
                </thead>
                <tbody>
                  {yearPeriods.map((p) => (
                    <tr key={p.id}>
                      <td>{monthName(p.period_no)}</td>
                      <td className="mono">{fmtDate(p.start_date)}</td>
                      <td className="mono">{fmtDate(p.end_date)}</td>
                      <td><span className={`badge ${p.status === 'open' ? 'posted' : 'void'}`}>{p.status === 'open' ? 'مفتوحة' : 'مقفلة'}</span></td>
                      <td>
                        {p.status === 'open' && (
                          <button
                            disabled={busy || p.id !== nextCloseId}
                            title={p.id !== nextCloseId ? 'أقفل الفترات السابقة أولاً' : ''}
                            onClick={() => run(() => supabase.rpc('close_fiscal_period', { p_period_id: p.id }))}
                          >
                            إقفال
                          </button>
                        )}
                        {p.status === 'closed' && p.id !== nextReopenId && (
                          <span className="muted" style={{ fontSize: '0.8rem' }}>أعد فتح الفترات الأحدث أولاً</span>
                        )}
                        {p.status === 'closed' && p.id === nextReopenId && reopenTarget?.id !== p.id && (
                          <button disabled={busy} onClick={() => { setReopenTarget({ kind: 'period', id: p.id }); setReopenReason(''); }}>
                            إعادة فتح
                          </button>
                        )}
                        {reopenTarget?.kind === 'period' && reopenTarget.id === p.id && (
                          <div className="row">
                            <input className="grow" placeholder="السبب (إلزامي)" value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} />
                            <button className="btn-primary" disabled={busy || !reopenReason.trim()} onClick={submitReopen}>تأكيد</button>
                            <button disabled={busy} onClick={() => setReopenTarget(null)}>إلغاء</button>
                          </div>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      })}

      <div className="card">
        <h2>سجل الإقفال وإعادة الفتح</h2>
        <div style={{ overflowX: 'auto' }}>
          <table>
            <thead>
              <tr><th>السنة</th><th>الفترة</th><th>الإجراء</th><th>السبب</th><th>بواسطة</th><th>التاريخ</th></tr>
            </thead>
            <tbody>
              {!log?.length && <tr><td colSpan={6} className="muted">لا يوجد سجل بعد.</td></tr>}
              {log?.map((r) => (
                <tr key={r.id}>
                  <td className="mono">{r.fiscal_year_code}</td>
                  <td>{r.period_no ? monthName(r.period_no) : <span className="muted">السنة كاملة</span>}</td>
                  <td><span className={`badge ${r.action === 'close' ? 'void' : 'posted'}`}>{r.action === 'close' ? 'إقفال' : 'إعادة فتح'}</span></td>
                  <td>{r.reason ?? '—'}</td>
                  <td className="muted">{r.done_by_email ?? '—'}</td>
                  <td className="mono">{fmtDate(r.done_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
