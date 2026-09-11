import type { ReactNode } from 'react';
import { NavLink } from 'react-router-dom';
import { useAuth } from '../lib/auth.tsx';
import { useOrg } from '../lib/org.tsx';

const nav = [
  { to: '/', label: 'الرئيسية' },
  { to: '/customers', label: 'العملاء' },
  { to: '/suppliers', label: 'الموردون' },
  { to: '/employees', label: 'الموظفون' },
  { to: '/items', label: 'الأصناف' },
  { to: '/stock-moves', label: 'حركات المخزون' },
  { to: '/sales-invoices', label: 'فواتير المبيعات' },
  { to: '/purchase-invoices', label: 'فواتير المشتريات' },
  { to: '/vouchers', label: 'السندات' },
  { to: '/cheques', label: 'الشيكات' },
  { to: '/journals', label: 'القيود' },
  { to: '/accounts', label: 'دليل الحسابات' },
  { to: '/currencies', label: 'العملات' },
];

export function Shell({ children }: { children: ReactNode }) {
  const { signOut } = useAuth();
  const { org } = useOrg();
  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">روتوبا</div>
        {nav.map((n) => (
          <NavLink key={n.to} to={n.to} end={n.to === '/'} className={({ isActive }) => (isActive ? 'active' : '')}>
            {n.label}
          </NavLink>
        ))}
        <div className="spacer" />
        <div className="muted" style={{ fontSize: '0.8rem', padding: '0 0.5rem' }}>{org?.name_ar}</div>
        <button onClick={signOut}>تسجيل الخروج</button>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
