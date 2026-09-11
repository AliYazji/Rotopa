import { Fragment, type ReactNode } from 'react';
import { NavLink } from 'react-router-dom';
import { useAuth } from '../lib/auth.tsx';
import { useOrg } from '../lib/org.tsx';

const nav: { section: string | null; items: { to: string; label: string }[] }[] = [
  { section: null, items: [{ to: '/', label: 'الرئيسية' }] },
  {
    section: 'الأطراف',
    items: [
      { to: '/customers', label: 'العملاء' },
      { to: '/suppliers', label: 'الموردون' },
      { to: '/employees', label: 'الموظفون' },
    ],
  },
  {
    section: 'المخزون والمبيعات',
    items: [
      { to: '/items', label: 'الأصناف' },
      { to: '/stock-moves', label: 'حركات المخزون' },
      { to: '/pos', label: 'الكاشير' },
      { to: '/sales-invoices', label: 'فواتير المبيعات' },
      { to: '/purchase-invoices', label: 'فواتير المشتريات' },
    ],
  },
  {
    section: 'الموارد',
    items: [
      { to: '/fixed-assets', label: 'الأصول الثابتة' },
      { to: '/payroll', label: 'الرواتب' },
    ],
  },
  {
    section: 'المحاسبة',
    items: [
      { to: '/vouchers', label: 'السندات' },
      { to: '/cheques', label: 'الشيكات' },
      { to: '/journals', label: 'القيود' },
      { to: '/accounts', label: 'دليل الحسابات' },
    ],
  },
  {
    section: 'التقارير',
    items: [
      { to: '/income-statement', label: 'قائمة الدخل' },
      { to: '/balance-sheet', label: 'الميزانية العمومية' },
    ],
  },
  { section: null, items: [{ to: '/currencies', label: 'العملات' }] },
];

export function Shell({ children }: { children: ReactNode }) {
  const { signOut } = useAuth();
  const { org } = useOrg();
  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">روتوبا</div>
        {nav.map((group, i) => (
          <Fragment key={group.section ?? `top-${i}`}>
            {group.section && <div className="section-label">{group.section}</div>}
            {group.items.map((n) => (
              <NavLink key={n.to} to={n.to} end={n.to === '/'} className={({ isActive }) => (isActive ? 'active' : '')}>
                {n.label}
              </NavLink>
            ))}
          </Fragment>
        ))}
        <div className="spacer" />
        <div className="muted" style={{ fontSize: '0.8rem', padding: '0 0.5rem' }}>{org?.name_ar}</div>
        <button onClick={signOut}>تسجيل الخروج</button>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
