import { Fragment, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, translateError } from '../lib/format.ts';

interface LogRow {
  id: number; user_id: string | null; user_email: string | null; action: 'INSERT' | 'UPDATE' | 'DELETE';
  table_name: string; record_id: string | null;
  before_data: Record<string, unknown> | null; after_data: Record<string, unknown> | null;
  at: string; total_count: number;
}
interface TableOpt { table_name: string; entry_count: number; }
interface ActorOpt { user_id: string; user_email: string | null; }

const TABLE_LABEL: Record<string, string> = {
  accounts: 'الحسابات', currencies: 'العملات', exchange_rates: 'أسعار الصرف',
  fiscal_years: 'السنوات المالية', fiscal_periods: 'الفترات المحاسبية',
  journal_entries: 'القيود', journal_lines: 'أطراف القيود',
  vouchers: 'السندات', cheques: 'الشيكات', dealers: 'الأطراف (عملاء/موردون/موظفون)',
  items: 'الأصناف', warehouses: 'المستودعات', stock_moves: 'حركات المخزون',
  sales_invoices: 'فواتير المبيعات', purchase_invoices: 'فواتير المشتريات',
  sales_returns: 'مرتجعات المبيعات', purchase_returns: 'مرتجعات المشتريات',
  sales_orders: 'طلبات البيع', purchase_orders: 'طلبات الشراء',
  fixed_assets: 'الأصول الثابتة', payroll_runs: 'كشوف الرواتب',
  roles: 'الأدوار', role_permissions: 'صلاحيات الأدوار', memberships: 'العضويات',
  branches: 'الفروع', org_settings: 'إعدادات المؤسسة',
};
const ACTION_LABEL: Record<string, string> = { INSERT: 'إضافة', UPDATE: 'تعديل', DELETE: 'حذف' };
const PAGE_SIZE = 50;

function diffRows(before: Record<string, unknown> | null, after: Record<string, unknown> | null) {
  const keys = new Set([...(before ? Object.keys(before) : []), ...(after ? Object.keys(after) : [])]);
  const rows: { key: string; before: unknown; after: unknown }[] = [];
  for (const k of keys) {
    const b = before?.[k];
    const a = after?.[k];
    if (JSON.stringify(b) !== JSON.stringify(a)) rows.push({ key: k, before: b, after: a });
  }
  return rows.sort((x, y) => x.key.localeCompare(y.key));
}
const showVal = (v: unknown) => (v === undefined || v === null ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v));

export default function AuditLog() {
  const { org } = useOrg();
  const [tableName, setTableName] = useState('');
  const [action, setAction] = useState('');
  const [userId, setUserId] = useState('');
  const [recordId, setRecordId] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(0);
  const [expanded, setExpanded] = useState<number | null>(null);

  const { data: tables } = useQuery({
    queryKey: ['audit-tables', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<TableOpt[]> => {
      const { data, error } = await supabase.rpc('audit_log_table_names', { p_org: org!.id });
      if (error) throw error;
      return data as TableOpt[];
    },
  });

  const { data: actors } = useQuery({
    queryKey: ['audit-actors', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<ActorOpt[]> => {
      const { data, error } = await supabase.rpc('audit_log_actors', { p_org: org!.id });
      if (error) throw error;
      return data as ActorOpt[];
    },
  });

  const { data: rows, isLoading, error } = useQuery({
    queryKey: ['audit-log', org?.id, tableName, action, userId, recordId, from, to, page],
    enabled: !!org,
    queryFn: async (): Promise<LogRow[]> => {
      const { data, error } = await supabase.rpc('audit_log_query', {
        p_org: org!.id,
        p_table_name: tableName || null,
        p_action: action || null,
        p_user_id: userId || null,
        p_record_id: recordId.trim() || null,
        p_from: from ? new Date(from).toISOString() : null,
        p_to: to ? new Date(to + 'T23:59:59').toISOString() : null,
        p_limit: PAGE_SIZE,
        p_offset: page * PAGE_SIZE,
      });
      if (error) throw error;
      return data as LogRow[];
    },
  });

  const total = rows?.[0]?.total_count ?? 0;
  const resetPage = () => setPage(0);

  return (
    <>
      <h1>سجل التدقيق</h1>

      <div className="card">
        <div className="row">
          <div className="field" style={{ minWidth: 180 }}>
            <label>الجدول</label>
            <select value={tableName} onChange={(e) => { setTableName(e.target.value); resetPage(); }}>
              <option value="">الكل</option>
              {tables?.map((t) => (
                <option key={t.table_name} value={t.table_name}>
                  {TABLE_LABEL[t.table_name] ?? t.table_name} ({t.entry_count})
                </option>
              ))}
            </select>
          </div>
          <div className="field" style={{ minWidth: 140 }}>
            <label>نوع العملية</label>
            <select value={action} onChange={(e) => { setAction(e.target.value); resetPage(); }}>
              <option value="">الكل</option>
              <option value="INSERT">إضافة</option>
              <option value="UPDATE">تعديل</option>
              <option value="DELETE">حذف</option>
            </select>
          </div>
          <div className="field" style={{ minWidth: 200 }}>
            <label>المستخدم</label>
            <select value={userId} onChange={(e) => { setUserId(e.target.value); resetPage(); }}>
              <option value="">الكل</option>
              {actors?.map((a) => <option key={a.user_id} value={a.user_id}>{a.user_email ?? a.user_id}</option>)}
            </select>
          </div>
          <div className="field" style={{ minWidth: 160 }}>
            <label>معرّف السجل</label>
            <input value={recordId} onChange={(e) => { setRecordId(e.target.value); resetPage(); }} placeholder="UUID اختياري" dir="ltr" />
          </div>
          <div className="field" style={{ width: 150 }}>
            <label>من تاريخ</label>
            <input type="date" value={from} onChange={(e) => { setFrom(e.target.value); resetPage(); }} />
          </div>
          <div className="field" style={{ width: 150 }}>
            <label>إلى تاريخ</label>
            <input type="date" value={to} onChange={(e) => { setTo(e.target.value); resetPage(); }} />
          </div>
        </div>
      </div>

      {error && <p className="error">{translateError((error as Error).message)}</p>}

      <div className="card" style={{ marginTop: '1rem', padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr><th>التاريخ والوقت</th><th>الجدول</th><th>العملية</th><th>المستخدم</th><th>معرّف السجل</th><th style={{ width: 80 }} /></tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={6} className="muted">جارٍ التحميل…</td></tr>}
            {!isLoading && !rows?.length && <tr><td colSpan={6} className="muted">لا توجد نتائج مطابقة.</td></tr>}
            {rows?.map((r) => (
              <Fragment key={r.id}>
                <tr className="rowlink" onClick={() => setExpanded(expanded === r.id ? null : r.id)}>
                  <td className="mono">{fmtDate(r.at)} {new Date(r.at).toLocaleTimeString('ar-EG-u-nu-latn', { hour: '2-digit', minute: '2-digit' })}</td>
                  <td>{TABLE_LABEL[r.table_name] ?? r.table_name}</td>
                  <td><span className={`badge ${r.action === 'DELETE' ? 'void' : r.action === 'INSERT' ? 'posted' : 'draft'}`}>{ACTION_LABEL[r.action]}</span></td>
                  <td className="muted">{r.user_email ?? '—'}</td>
                  <td className="mono" style={{ fontSize: '0.8rem' }}>{r.record_id ?? '—'}</td>
                  <td>{expanded === r.id ? '▲' : '▼'}</td>
                </tr>
                {expanded === r.id && (
                  <tr>
                    <td colSpan={6} style={{ background: 'var(--surface-2)' }}>
                      {diffRows(r.before_data, r.after_data).length === 0 ? (
                        <p className="muted" style={{ margin: '0.5rem' }}>لا يوجد فرق بالحقول (تحديث بلا تغيير قيمة).</p>
                      ) : (
                        <table style={{ margin: '0.5rem 0' }}>
                          <thead><tr><th>الحقل</th><th>قبل</th><th>بعد</th></tr></thead>
                          <tbody>
                            {diffRows(r.before_data, r.after_data).map((d) => (
                              <tr key={d.key}>
                                <td className="mono">{d.key}</td>
                                <td className="mono" style={{ color: 'var(--debit)' }}>{showVal(d.before)}</td>
                                <td className="mono" style={{ color: 'var(--credit)' }}>{showVal(d.after)}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      )}
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>

      {total > PAGE_SIZE && (
        <div className="row" style={{ marginTop: '0.75rem', justifyContent: 'space-between' }}>
          <span className="muted">
            {page * PAGE_SIZE + 1}–{Math.min((page + 1) * PAGE_SIZE, total)} من {total}
          </span>
          <div className="row">
            <button disabled={page === 0} onClick={() => setPage((p) => p - 1)}>السابق ›</button>
            <button disabled={(page + 1) * PAGE_SIZE >= total} onClick={() => setPage((p) => p + 1)}>‹ التالي</button>
          </div>
        </div>
      )}
    </>
  );
}
