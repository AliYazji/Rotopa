import { Fragment, useEffect, useState, type ReactNode } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useAuth } from '../lib/auth.tsx';
import { useOrg } from '../lib/org.tsx';
import { supabase } from '../lib/supabase.ts';

// Grouped by BUSINESS PROCESS (a full sales cycle together, a full purchase
// cycle together), not by document type or by "which party" — matching how
// Odoo/دفترة organize their own nav, per an explicit user request to align
// with that convention instead of the doctype-first grouping this grew into
// organically over the session.
const nav: { section: string | null; items: { to: string; label: string }[] }[] = [
  { section: null, items: [{ to: '/', label: 'الرئيسية' }] },
  {
    section: 'المبيعات',
    items: [
      { to: '/customers', label: 'العملاء' },
      { to: '/sales-orders', label: 'طلبات البيع' },
      { to: '/sales-invoices', label: 'فواتير المبيعات' },
      { to: '/sales-returns', label: 'مرتجعات المبيعات' },
      { to: '/pos', label: 'الكاشير' },
    ],
  },
  {
    section: 'المشتريات',
    items: [
      { to: '/suppliers', label: 'الموردون' },
      { to: '/purchase-orders', label: 'طلبات الشراء' },
      { to: '/purchase-invoices', label: 'فواتير المشتريات' },
      { to: '/purchase-returns', label: 'مرتجعات المشتريات' },
    ],
  },
  {
    section: 'المخزون',
    items: [
      { to: '/items', label: 'الأصناف' },
      { to: '/stock-moves', label: 'حركات المخزون' },
      { to: '/stock-reservations', label: 'حجز المخزون' },
    ],
  },
  {
    section: 'المحاسبة',
    items: [
      { to: '/journals', label: 'القيود' },
      { to: '/vouchers', label: 'السندات' },
      { to: '/cheques', label: 'الشيكات' },
    ],
  },
  {
    section: 'التقارير',
    items: [
      { to: '/trial-balance', label: 'ميزان المراجعة' },
      { to: '/income-statement', label: 'قائمة الدخل' },
      { to: '/balance-sheet', label: 'الميزانية العمومية' },
      { to: '/ar-aging', label: 'أعمار ديون العملاء' },
      { to: '/ap-aging', label: 'أعمار ديون الموردين' },
    ],
  },
  { section: 'الأصول الثابتة', items: [{ to: '/fixed-assets', label: 'الأصول الثابتة' }] },
  {
    section: 'الموارد البشرية',
    items: [
      { to: '/employees', label: 'الموظفون' },
      { to: '/payroll', label: 'الرواتب' },
    ],
  },
  {
    section: 'الفندقة',
    items: [
      { to: '/rooms', label: 'الغرف وأنواعها' },
      { to: '/reservations', label: 'الحجوزات' },
    ],
  },
  {
    section: 'المطعم',
    items: [
      { to: '/outlets', label: 'المنافذ والطاولات' },
      { to: '/pos-orders', label: 'طلبات الكاشير' },
    ],
  },
  {
    section: 'الإعدادات',
    items: [
      { to: '/accounts', label: 'دليل الحسابات' },
      { to: '/currencies', label: 'العملات' },
      { to: '/team', label: 'الفريق' },
      { to: '/roles', label: 'الأدوار والصلاحيات' },
      { to: '/periods', label: 'الفترات المحاسبية' },
      { to: '/audit-log', label: 'سجل التدقيق' },
      { to: '/settings', label: 'إعدادات المؤسسة' },
    ],
  },
];

// A minimal "things waiting on someone" indicator — deliberately NOT a real
// notification system (no persistence, no dismissing, no realtime push):
// it just surfaces the same worklist counts the dashboard already computes
// in dashboard_summary(), as a badge that gets your attention before you'd
// otherwise navigate to "/" and see them anyway.
function usePendingCount(orgId: string | undefined) {
  const { data } = useQuery({
    queryKey: ['shell-pending-count', orgId],
    enabled: !!orgId,
    refetchInterval: 60_000,
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('dashboard_summary', { p_org: orgId });
      if (error) throw error;
      const s = data?.[0];
      if (!s) return 0;
      return s.draft_sales_invoices + s.draft_purchase_invoices + s.open_sales_orders + s.open_purchase_orders + s.pending_invitations;
    },
  });
  return data ?? 0;
}

export function Shell({ children }: { children: ReactNode }) {
  const { signOut, signOutEverywhere } = useAuth();
  const { org } = useOrg();
  const [open, setOpen] = useState(false);
  const location = useLocation();
  const pending = usePendingCount(org?.id);

  // close the mobile drawer whenever the route changes
  useEffect(() => { setOpen(false); }, [location.pathname]);

  return (
    <div className="shell">
      <div className="topbar">
        <button onClick={() => setOpen(true)} aria-label="القائمة" className="menu-btn">☰</button>
        <div className="brand">روتوبا</div>
        {pending > 0 && (
          <NavLink to="/" className="badge void" style={{ marginInlineStart: 'auto', textDecoration: 'none' }}>
            {pending} بانتظار الإجراء
          </NavLink>
        )}
      </div>
      {open && <div className="backdrop" onClick={() => setOpen(false)} />}
      <aside className={`side${open ? ' open' : ''}`}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <div className="brand">روتوبا</div>
          <button onClick={() => setOpen(false)} aria-label="إغلاق القائمة" className="side-close">×</button>
        </div>
        {nav.map((group, i) => (
          <Fragment key={group.section ?? `top-${i}`}>
            {group.section && <div className="section-label">{group.section}</div>}
            {group.items.map((n) => (
              <NavLink key={n.to} to={n.to} end={n.to === '/'} className={({ isActive }) => (isActive ? 'active' : '')}>
                <span className="row" style={{ justifyContent: 'space-between', gap: '0.4rem' }}>
                  {n.label}
                  {n.to === '/' && pending > 0 && <span className="badge void">{pending}</span>}
                </span>
              </NavLink>
            ))}
          </Fragment>
        ))}
        <div className="spacer" />
        <div className="muted" style={{ fontSize: '0.8rem', padding: '0 0.5rem' }}>{org?.name_ar}</div>
        <button onClick={signOut}>تسجيل الخروج</button>
        <button
          onClick={() => { if (confirm('تسجيل الخروج من كل الأجهزة والجلسات؟')) signOutEverywhere(); }}
          style={{ fontSize: '0.8rem' }}
        >
          تسجيل الخروج من كل الأجهزة
        </button>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
