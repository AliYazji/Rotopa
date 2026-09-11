import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './lib/auth.tsx';
import { OrgProvider, useOrg } from './lib/org.tsx';
import { Shell } from './components/Shell.tsx';
import Login from './pages/Login.tsx';
import Onboarding from './pages/Onboarding.tsx';
import Dashboard from './pages/Dashboard.tsx';
import Accounts from './pages/Accounts.tsx';
import Journals from './pages/Journals.tsx';
import JournalNew from './pages/JournalNew.tsx';
import Vouchers from './pages/Vouchers.tsx';
import VoucherNew from './pages/VoucherNew.tsx';
import Currencies from './pages/Currencies.tsx';

function Gate() {
  const { org, loading } = useOrg();
  if (loading) return <div className="main">جارٍ التحميل…</div>;
  if (!org) return <Onboarding />;
  return (
    <Shell>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/accounts" element={<Accounts />} />
        <Route path="/journals" element={<Journals />} />
        <Route path="/journals/new" element={<JournalNew />} />
        <Route path="/vouchers" element={<Vouchers />} />
        <Route path="/vouchers/new" element={<VoucherNew />} />
        <Route path="/currencies" element={<Currencies />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Shell>
  );
}

export default function App() {
  const { session, loading } = useAuth();
  if (loading) return <div className="main">جارٍ التحميل…</div>;
  if (!session) return <Login />;
  return (
    <OrgProvider>
      <Gate />
    </OrgProvider>
  );
}
