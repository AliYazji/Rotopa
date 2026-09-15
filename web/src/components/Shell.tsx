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
      { to: '/item-categories', label: 'فئات الأصناف' },
      { to: '/warehouses', label: 'المستودعات' },
      { to: '/stock-moves', label: 'حركات المخزون' },
      { to: '/stock-reservations', label: 'حجز المخزون' },
      { to: '/manufacturing-orders', label: 'أوامر التصنيع' },
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
      { to: '/account-categories', label: 'تصنيفات الحسابات' },
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

// Which section a path belongs to, so the sidebar can auto-expand it.
function sectionForPath(pathname: string): string | null {
  for (const group of nav) {
    if (!group.section) continue;
    if (group.items.some((n) => (n.to === '/' ? pathname === '/' : pathname === n.to || pathname.startsWith(n.to + '/')))) {
      return group.section;
    }
  }
  return null;
}

const OPEN_SECTIONS_KEY = 'rotopa.sidebar.openSections';

export function Shell({ children }: { children: ReactNode }) {
  const { signOut, signOutEverywhere } = useAuth();
  const { org } = useOrg();
  const [open, setOpen] = useState(false);
  const location = useLocation();
  const pending = usePendingCount(org?.id);

  // Collapsible sections — remembered per browser (localStorage), and the
  // section containing whatever page you're actually on always stays open
  // even if you'd previously collapsed it, so navigating never hides where
  // you are. Long sidebar (9 sections) otherwise meant scrolling past
  // everything just to reach the page you wanted.
  const [openSections, setOpenSections] = useState<Set<string>>(() => {
    try {
      const saved = localStorage.getItem(OPEN_SECTIONS_KEY);
      if (saved) return new Set(JSON.parse(saved));
    } catch { /* localStorage unavailable — fall through to the default */ }
    const active = sectionForPath(location.pathname);
    return new Set(active ? [active] : []);
  });

  function toggleSection(section: string) {
    setOpenSections((prev) => {
      const next = new Set(prev);
      if (next.has(section)) next.delete(section); else next.add(section);
      try { localStorage.setItem(OPEN_SECTIONS_KEY, JSON.stringify([...next])); } catch { /* ignore */ }
      return next;
    });
  }

  // close the mobile drawer whenever the route changes; keep the current
  // page's section expanded regardless of its saved collapsed state
  useEffect(() => {
    setOpen(false);
    const active = sectionForPath(location.pathname);
    if (active) setOpenSections((prev) => (prev.has(active) ? prev : new Set(prev).add(active)));
  }, [location.pathname]);

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
        {nav.map((group, i) => {
          const isOpen = !group.section || openSections.has(group.section);
          return (
            <Fragment key={group.section ?? `top-${i}`}>
              {group.section && (
                <button
                  type="button"
                  className={`section-label section-toggle${isOpen ? ' open' : ''}`}
                  onClick={() => toggleSection(group.section!)}
                  aria-expanded={isOpen}
                >
                  <span>{group.section}</span>
                  <span className="chevron">▾</span>
                </button>
              )}
              {isOpen && group.items.map((n) => (
                <NavLink key={n.to} to={n.to} end={n.to === '/'} className={({ isActive }) => (isActive ? 'active' : '')}>
                  <span className="row" style={{ justifyContent: 'space-between', gap: '0.4rem' }}>
                    {n.label}
                    {n.to === '/' && pending > 0 && <span className="badge void">{pending}</span>}
                  </span>
                </NavLink>
              ))}
            </Fragment>
          );
        })}
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
