import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, fmtPct, today, translateError } from '../lib/format.ts';

interface ReturnDoc {
  id: string; return_no: number; return_date: string; status: 'draft' | 'posted' | 'void';
  payment_method: 'credit' | 'cash'; description: string; void_reason: string | null;
  sales_invoice: { invoice_no: number; tax_rate: number } | null; dealer: { name_ar: string } | null;
  tax_rate: number; tax_amount: number;
}
interface Line {
  id: string; line_no: number; item_id: string; qty: number; unit_price: number; unit_cost: number; line_total: number;
  item: { code: string; name_ar: string; base_unit_name: string } | null;
}
interface AccOpt { id: string; code: string; name_ar: string; }

const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّل', void: 'ملغى' };

export default function SalesReturnDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { taxEnabled, defaultAccounts } = useOrg();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [defaultSalesAccountId, setDefaultSalesAccountId] = useState('');
  const [vatAccountId, setVatAccountId] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setDefaultSalesAccountId((v) => v || defaultAccounts.salesAccountId);
    setVatAccountId((v) => v || defaultAccounts.outputVatAccountId);
  }, [defaultAccounts]);

  const { data: ret, isLoading } = useQuery({
    queryKey: ['sales-return', id],
    enabled: !!id,
    queryFn: async (): Promise<ReturnDoc> => {
      const { data, error } = await supabase.from('sales_returns')
        .select('id, return_no, return_date, status, payment_method, description, void_reason, tax_rate, tax_amount, sales_invoice:sales_invoice_id(invoice_no, tax_rate), dealer:dealer_id(name_ar)')
        .eq('id', id).single();
      if (error) throw error;
      return data as unknown as ReturnDoc;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['sales-return-lines', id],
    enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('sales_return_lines')
        .select('id, line_no, item_id, qty, unit_price, unit_cost, line_total, item:item_id(code, name_ar, base_unit_name)')
        .eq('return_id', id).order('line_no');
      if (error) throw error;
      return data as unknown as Line[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts'],
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['sales-return', id] });
    await qc.invalidateQueries({ queryKey: ['sales-return-lines', id] });
    await qc.invalidateQueries({ queryKey: ['sales-returns'] });
  }

  async function postReturn() {
    setErr(null); setBusy(true);
    if (taxEnabled && !vatAccountId) { setBusy(false); return setErr('اختر حساب ضريبة المخرجات'); }
    const { error } = await supabase.rpc('post_sales_return', {
      p_return_id: id, p_default_sales_account_id: defaultSalesAccountId || null, p_output_vat_account_id: taxEnabled ? vatAccountId : null,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('sales_returns').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/sales-returns');
  }

  async function voidReturn() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('void_sales_return', { p_return_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }

  if (isLoading || !ret) return <p className="muted">جارٍ التحميل…</p>;
  const total = (lines ?? []).reduce((s, l) => s + Number(l.line_total), 0);
  // a posted/void return already has its VAT frozen (computed at post time
  // from the ORIGINAL invoice's own frozen rate, never the org's live
  // setting); a still-draft return previews using that same original
  // invoice rate — never the org's current live rate either, since that is
  // never what post_sales_return() will actually use
  const isFrozen = ret.status !== 'draft';
  const displayVatRate = isFrozen ? Number(ret.tax_rate) : Number(ret.sales_invoice?.tax_rate ?? 0);
  const displayVat = isFrozen ? Number(ret.tax_amount) : total * displayVatRate;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>مرجع مبيعات رقم {ret.return_no}</h1>
        <span className={`badge ${ret.status}`}>{STATUS[ret.status]}</span>
      </div>
      <p className="muted">
        {fmtDate(ret.return_date)} · {ret.dealer?.name_ar} · على فاتورة رقم {ret.sales_invoice?.invoice_no} ·{' '}
        {ret.payment_method === 'cash' ? 'رد نقدي' : 'رد لحساب العميل'}
      </p>

      <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
        <table>
          <thead>
            <tr>
              <th>الصنف</th>
              <th className="num" style={{ width: 90 }}>الكمية</th>
              <th className="num" style={{ width: 100 }}>السعر</th>
              <th className="num" style={{ width: 100 }}>الإجمالي</th>
              {ret.status !== 'draft' && <th className="num" style={{ width: 100 }}>التكلفة المعادة</th>}
            </tr>
          </thead>
          <tbody>
            {lines?.map((l) => (
              <tr key={l.id}>
                <td>{l.item?.code} · {l.item?.name_ar}</td>
                <td className="num">{fmtMoney(l.qty)} {l.item?.base_unit_name}</td>
                <td className="num">{fmtMoney(l.unit_price)}</td>
                <td className="num">{fmtMoney(l.line_total)}</td>
                {ret.status !== 'draft' && <td className="num muted">{fmtMoney(l.unit_cost)}</td>}
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><td colSpan={3}>المجموع قبل الضريبة</td><td className="num">{fmtMoney(total)}</td>{ret.status !== 'draft' && <td />}</tr>
            {taxEnabled && <tr className="muted"><td colSpan={3}>ضريبة القيمة المضافة ({fmtPct(displayVatRate)})</td><td className="num">{fmtMoney(displayVat)}</td>{ret.status !== 'draft' && <td />}</tr>}
            <tr style={{ fontWeight: 700 }}><td colSpan={3}>الإجمالي شامل الضريبة</td><td className="num">{fmtMoney(total + displayVat)}</td>{ret.status !== 'draft' && <td />}</tr>
          </tfoot>
        </table>
      </div>

      {ret.status === 'draft' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <h2 style={{ fontSize: '0.95rem' }}>ترحيل المرجع</h2>
          <div className="field">
            <label>حساب المبيعات الافتراضي (لأي صنف بلا حساب خاص)</label>
            <select value={defaultSalesAccountId} onChange={(e) => setDefaultSalesAccountId(e.target.value)}>
              <option value="">—</option>
              {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
            </select>
          </div>
          {taxEnabled && (
            <div className="field">
              <label>حساب ضريبة المخرجات</label>
              <select value={vatAccountId} onChange={(e) => setVatAccountId(e.target.value)}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          )}
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postReturn}>ترحيل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}

      {ret.status === 'posted' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء المرجع</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>بيسحب البضاعة من المخزون مرة ثانية ويعكس القيد.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <button className="btn-danger" disabled={busy} onClick={voidReturn}>إلغاء المرجع</button>
        </div>
      )}

      {ret.status === 'void' && (
        <div className="card" style={{ maxWidth: 460 }}>
          <p className="muted" style={{ marginTop: 0 }}>أُلغي{ret.void_reason ? ` — ${ret.void_reason}` : ''}.</p>
        </div>
      )}

      <p style={{ marginTop: '1rem' }}><Link to="/sales-returns">‹ رجوع لقائمة مرتجعات المبيعات</Link></p>
    </>
  );
}
