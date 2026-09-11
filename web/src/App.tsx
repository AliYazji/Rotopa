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
import JournalDetail from './pages/JournalDetail.tsx';
import Vouchers from './pages/Vouchers.tsx';
import VoucherNew from './pages/VoucherNew.tsx';
import VoucherDetail from './pages/VoucherDetail.tsx';
import Cheques from './pages/Cheques.tsx';
import ChequeNew from './pages/ChequeNew.tsx';
import Items from './pages/Items.tsx';
import ItemNew from './pages/ItemNew.tsx';
import ItemDetail from './pages/ItemDetail.tsx';
import StockMoves from './pages/StockMoves.tsx';
import StockMoveNew from './pages/StockMoveNew.tsx';
import StockMoveDetail from './pages/StockMoveDetail.tsx';
import SalesInvoices from './pages/SalesInvoices.tsx';
import SalesInvoiceNew from './pages/SalesInvoiceNew.tsx';
import SalesInvoiceDetail from './pages/SalesInvoiceDetail.tsx';
import PosCheckout from './pages/PosCheckout.tsx';
import PurchaseInvoices from './pages/PurchaseInvoices.tsx';
import PurchaseInvoiceNew from './pages/PurchaseInvoiceNew.tsx';
import PurchaseInvoiceDetail from './pages/PurchaseInvoiceDetail.tsx';
import FixedAssets from './pages/FixedAssets.tsx';
import FixedAssetNew from './pages/FixedAssetNew.tsx';
import FixedAssetDetail from './pages/FixedAssetDetail.tsx';
import PayrollRuns from './pages/PayrollRuns.tsx';
import PayrollRunNew from './pages/PayrollRunNew.tsx';
import PayrollRunDetail from './pages/PayrollRunDetail.tsx';
import IncomeStatement from './pages/IncomeStatement.tsx';
import BalanceSheet from './pages/BalanceSheet.tsx';
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
        <Route path="/journals/:id" element={<JournalDetail />} />
        <Route path="/vouchers" element={<Vouchers />} />
        <Route path="/vouchers/new" element={<VoucherNew />} />
        <Route path="/vouchers/:id" element={<VoucherDetail />} />
        <Route path="/cheques" element={<Cheques />} />
        <Route path="/cheques/new" element={<ChequeNew />} />
        <Route path="/items" element={<Items />} />
        <Route path="/items/new" element={<ItemNew />} />
        <Route path="/items/:id" element={<ItemDetail />} />
        <Route path="/stock-moves" element={<StockMoves />} />
        <Route path="/stock-moves/new" element={<StockMoveNew />} />
        <Route path="/stock-moves/:id" element={<StockMoveDetail />} />
        <Route path="/sales-invoices" element={<SalesInvoices />} />
        <Route path="/sales-invoices/new" element={<SalesInvoiceNew />} />
        <Route path="/sales-invoices/:id" element={<SalesInvoiceDetail />} />
        <Route path="/pos" element={<PosCheckout />} />
        <Route path="/purchase-invoices" element={<PurchaseInvoices />} />
        <Route path="/purchase-invoices/new" element={<PurchaseInvoiceNew />} />
        <Route path="/purchase-invoices/:id" element={<PurchaseInvoiceDetail />} />
        <Route path="/fixed-assets" element={<FixedAssets />} />
        <Route path="/fixed-assets/new" element={<FixedAssetNew />} />
        <Route path="/fixed-assets/:id" element={<FixedAssetDetail />} />
        <Route path="/payroll" element={<PayrollRuns />} />
        <Route path="/payroll/new" element={<PayrollRunNew />} />
        <Route path="/payroll/:id" element={<PayrollRunDetail />} />
        <Route path="/income-statement" element={<IncomeStatement />} />
        <Route path="/balance-sheet" element={<BalanceSheet />} />
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
