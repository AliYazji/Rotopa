import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './lib/auth.tsx';
import { OrgProvider, useOrg } from './lib/org.tsx';
import { Shell } from './components/Shell.tsx';
import Login from './pages/Login.tsx';
import Onboarding from './pages/Onboarding.tsx';
import Dashboard from './pages/Dashboard.tsx';
import Accounts from './pages/Accounts.tsx';
import AccountNew from './pages/AccountNew.tsx';
import AccountDetail from './pages/AccountDetail.tsx';
import Customers from './pages/Customers.tsx';
import Suppliers from './pages/Suppliers.tsx';
import Employees from './pages/Employees.tsx';
import DealerNew from './pages/DealerNew.tsx';
import DealerDetail from './pages/DealerDetail.tsx';
import Journals from './pages/Journals.tsx';
import JournalNew from './pages/JournalNew.tsx';
import Vouchers from './pages/Vouchers.tsx';
import VoucherNew from './pages/VoucherNew.tsx';
import Cheques from './pages/Cheques.tsx';
import ChequeNew from './pages/ChequeNew.tsx';
import Items from './pages/Items.tsx';
import ItemNew from './pages/ItemNew.tsx';
import ItemDetail from './pages/ItemDetail.tsx';
import StockMoves from './pages/StockMoves.tsx';
import StockMoveNew from './pages/StockMoveNew.tsx';
import SalesInvoices from './pages/SalesInvoices.tsx';
import SalesInvoiceNew from './pages/SalesInvoiceNew.tsx';
import SalesInvoiceDetail from './pages/SalesInvoiceDetail.tsx';
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
        <Route path="/accounts/new" element={<AccountNew />} />
        <Route path="/accounts/:id" element={<AccountDetail />} />
        <Route path="/customers" element={<Customers />} />
        <Route path="/suppliers" element={<Suppliers />} />
        <Route path="/employees" element={<Employees />} />
        <Route path="/dealers/new" element={<DealerNew />} />
        <Route path="/dealers/:id" element={<DealerDetail />} />
        <Route path="/journals" element={<Journals />} />
        <Route path="/journals/new" element={<JournalNew />} />
        <Route path="/vouchers" element={<Vouchers />} />
        <Route path="/vouchers/new" element={<VoucherNew />} />
        <Route path="/cheques" element={<Cheques />} />
        <Route path="/cheques/new" element={<ChequeNew />} />
        <Route path="/items" element={<Items />} />
        <Route path="/items/new" element={<ItemNew />} />
        <Route path="/items/:id" element={<ItemDetail />} />
        <Route path="/stock-moves" element={<StockMoves />} />
        <Route path="/stock-moves/new" element={<StockMoveNew />} />
        <Route path="/sales-invoices" element={<SalesInvoices />} />
        <Route path="/sales-invoices/new" element={<SalesInvoiceNew />} />
        <Route path="/sales-invoices/:id" element={<SalesInvoiceDetail />} />
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
