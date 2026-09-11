import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { VAT_RATE, fmtMoney, sanitizeSearchTerm, today, translateError } from '../lib/format.ts';

interface WhOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }
interface CatOpt { id: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; }
interface ItemHit {
  id: string; code: string; name_ar: string; sales_price: number; base_unit_name: string; category_id: string | null;
  item_warehouse_balances: { qty: number; warehouse_id: string }[];
}
interface CartLine { itemId: string; code: string; name: string; unitPrice: number; unit: string; qty: number; onHand: number | null }

const WALKIN_CODE = 'CASH-WALKIN';
const SETTINGS_KEYS = ['warehouseId', 'vatAccountId', 'defaultSalesAccountId', 'cashAccountId'] as const;
type Settings = Record<(typeof SETTINGS_KEYS)[number], string>;
const emptySettings: Settings = { warehouseId: '', vatAccountId: '', defaultSalesAccountId: '', cashAccountId: '' };

export default function PosCheckout() {
  const { org } = useOrg();
  const nav = useNavigate();
  const qc = useQueryClient();

  const [settings, setSettings] = useState<Settings>(emptySettings);
  const [showSettings, setShowSettings] = useState(true);
  const [search, setSearch] = useState('');
  const [categoryId, setCategoryId] = useState('');
  const [cart, setCart] = useState<CartLine[]>([]);
  const [paymentType, setPaymentType] = useState<'credit' | 'cash'>('cash');
  const [dealerId, setDealerId] = useState('');
  const [walkinParentId, setWalkinParentId] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [lastInvoiceNo, setLastInvoiceNo] = useState<number | null>(null);

  useEffect(() => {
    if (!org) return;
    try {
      const raw = localStorage.getItem(`pos-settings-${org.id}`);
      if (raw) setSettings({ ...emptySettings, ...JSON.parse(raw) });
    } catch { /* ignore malformed/blocked storage */ }
  }, [org]);
  useEffect(() => {
    if (!org) return;
    try { localStorage.setItem(`pos-settings-${org.id}`, JSON.stringify(settings)); } catch { /* ignore */ }
  }, [org, settings]);

  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id], enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as WhOpt[];
    },
  });
  // most orgs only have one active warehouse — pick it automatically so the
  // item grid populates without a manual step; a real choice (or a saved
  // one from localStorage) always wins over this
  useEffect(() => {
    const firstId = warehouses?.[0]?.id;
    if (firstId) setSettings((s) => (s.warehouseId ? s : { ...s, warehouseId: firstId }));
  }, [warehouses]); // eslint-disable-line react-hooks/exhaustive-deps
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });
  const { data: headerAccounts } = useQuery({
    queryKey: ['header-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', false).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });
  const { data: categories } = useQuery({
    queryKey: ['item-categories', org?.id], enabled: !!org,
    queryFn: async (): Promise<CatOpt[]> => {
      const { data, error } = await supabase.from('item_categories').select('id, name_ar').order('name_ar');
      if (error) throw error; return data as CatOpt[];
    },
  });
  const { data: customers } = useQuery({
    queryKey: ['customers-lite', org?.id], enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar').eq('is_customer', true).order('name_ar').limit(500);
      if (error) throw error; return data as DealerOpt[];
    },
  });
  const { data: walkinDealer, refetch: refetchWalkin } = useQuery({
    queryKey: ['walkin-dealer', org?.id], enabled: !!org,
    queryFn: async (): Promise<{ id: string } | null> => {
      const { data, error } = await supabase.from('dealers').select('id').eq('org_id', org!.id).eq('code', WALKIN_CODE).maybeSingle();
      if (error) throw error; return data;
    },
  });

  const term = sanitizeSearchTerm(search);
  const { data: items } = useQuery({
    queryKey: ['pos-items', org?.id, term, categoryId, settings.warehouseId],
    enabled: !!org && !!settings.warehouseId,
    queryFn: async (): Promise<ItemHit[]> => {
      let q = supabase.from('items')
        .select('id, code, name_ar, sales_price, base_unit_name, category_id, item_warehouse_balances(qty, warehouse_id)')
        .eq('is_active', true).eq('is_stock_tracked', true).order('name_ar').limit(40);
      // no search/category chosen yet -> a default browse list (capped at
      // 40) instead of an empty grid; typing or picking a category narrows it
      if (term.length >= 2) q = q.or(`name_ar.ilike.%${term}%,code.ilike.%${term}%`);
      if (categoryId) q = q.eq('category_id', categoryId);
      const { data, error } = await q;
      if (error) throw error;
      return data as unknown as ItemHit[];
    },
  });

  function onHandOf(hit: ItemHit) {
    return Number(hit.item_warehouse_balances.find((b) => b.warehouse_id === settings.warehouseId)?.qty ?? 0);
  }

  const totals = useMemo(() => {
    const subtotal = cart.reduce((s, l) => s + l.unitPrice * l.qty, 0);
    const vat = subtotal * VAT_RATE;
    return { subtotal, vat, grand: subtotal + vat };
  }, [cart]);
  const overStockLine = cart.find((l) => l.onHand !== null && l.qty > l.onHand);

  function addToCart(hit: ItemHit) {
    setCart((ls) => {
      const existing = ls.find((l) => l.itemId === hit.id);
      if (existing) return ls.map((l) => (l.itemId === hit.id ? { ...l, qty: l.qty + 1 } : l));
      return [...ls, { itemId: hit.id, code: hit.code, name: hit.name_ar, unitPrice: hit.sales_price, unit: hit.base_unit_name, qty: 1, onHand: onHandOf(hit) }];
    });
  }
  function changeQty(itemId: string, delta: number) {
    setCart((ls) => ls.flatMap((l) => {
      if (l.itemId !== itemId) return [l];
      const qty = l.qty + delta;
      return qty <= 0 ? [] : [{ ...l, qty }];
    }));
  }
  function removeLine(itemId: string) {
    setCart((ls) => ls.filter((l) => l.itemId !== itemId));
  }

  async function createWalkinCustomer() {
    setErr(null); setBusy(true);
    try {
      if (!walkinParentId) throw new Error('اختر الحساب الأب لإنشاء "زبون نقدي عام"');
      const { error } = await supabase.rpc('create_dealer', {
        p_org: org!.id, p_name_ar: 'زبون نقدي عام', p_parent_account_id: walkinParentId,
        p_is_customer: true, p_code: WALKIN_CODE,
      });
      if (error) throw error;
      await refetchWalkin();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function checkout() {
    setErr(null);
    if (cart.length === 0) return setErr('السلة فاضية');
    if (!settings.warehouseId) return setErr('اختر المستودع من الإعدادات فوق');
    if (!settings.vatAccountId) return setErr('اختر حساب ضريبة المخرجات من الإعدادات فوق');
    if (overStockLine) return setErr(`الكمية المطلوبة لصنف "${overStockLine.name}" أكتر من المتوفر (${fmtMoney(overStockLine.onHand)}).`);
    // فوري defaults to the walk-in customer but can be any real customer too
    // (a regular customer paying cash instead of on credit); آجل must be a
    // real, specific customer — crediting the anonymous walk-in makes no sense.
    const effectiveDealerId = dealerId || (paymentType === 'cash' ? walkinDealer?.id : '');
    if (paymentType === 'credit' && (!dealerId || dealerId === walkinDealer?.id)) return setErr('اختر زبوناً مسجّلاً للبيع الآجل');
    if (paymentType === 'cash' && !settings.cashAccountId) return setErr('اختر الصندوق');
    if (!effectiveDealerId) return setErr('ما في زبون نقدي عام معرَّف بعد — أنشئه من الإعدادات فوق');

    setBusy(true);
    try {
      const { data: invoiceId, error } = await supabase.rpc('create_sales_invoice', {
        p_org: org!.id, p_invoice_date: today(), p_dealer_id: effectiveDealerId, p_warehouse_id: settings.warehouseId,
        p_lines: cart.map((l) => ({ item_id: l.itemId, qty: l.qty, unit_price: l.unitPrice })),
        p_payment_method: paymentType, p_cash_account_id: paymentType === 'cash' ? settings.cashAccountId : null,
      });
      if (error) throw error;

      const { error: pErr } = await supabase.rpc('post_sales_invoice', {
        p_invoice_id: invoiceId, p_default_sales_account_id: settings.defaultSalesAccountId || null,
        p_output_vat_account_id: settings.vatAccountId,
      });
      if (pErr) throw pErr;

      const { data: inv } = await supabase.from('sales_invoices').select('invoice_no').eq('id', invoiceId).single();
      setLastInvoiceNo(inv?.invoice_no ?? null);
      setCart([]); setDealerId('');
      await qc.invalidateQueries({ queryKey: ['sales-invoices'] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>الكاشير</h1>
        <button onClick={() => setShowSettings((s) => !s)}>{showSettings ? 'إخفاء الإعدادات' : 'إعدادات الجلسة'}</button>
      </div>

      {showSettings && (
        <div className="card" style={{ marginBottom: '1rem' }}>
          <div className="row" style={{ flexWrap: 'wrap' }}>
            <div className="field grow">
              <label>المستودع</label>
              <select value={settings.warehouseId} onChange={(e) => setSettings((s) => ({ ...s, warehouseId: e.target.value }))}>
                <option value="">—</option>
                {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
              </select>
            </div>
            <div className="field grow">
              <label>حساب ضريبة المخرجات</label>
              <select value={settings.vatAccountId} onChange={(e) => setSettings((s) => ({ ...s, vatAccountId: e.target.value }))}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
            <div className="field grow">
              <label>حساب المبيعات الافتراضي (لصنف بلا حساب خاص)</label>
              <select value={settings.defaultSalesAccountId} onChange={(e) => setSettings((s) => ({ ...s, defaultSalesAccountId: e.target.value }))}>
                <option value="">—</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          </div>
          {!walkinDealer && (
            <div className="row" style={{ alignItems: 'flex-end', marginTop: '0.5rem' }}>
              <div className="field grow">
                <label>ما في "زبون نقدي عام" بعد — اختر حساباً أباً لإنشائه (يُستخدم تلقائياً بكل بيع فوري)</label>
                <select value={walkinParentId} onChange={(e) => setWalkinParentId(e.target.value)}>
                  <option value="">—</option>
                  {headerAccounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
                </select>
              </div>
              <button disabled={busy} onClick={createWalkinCustomer}>إنشاء</button>
            </div>
          )}
        </div>
      )}

      {lastInvoiceNo != null && (
        <div className="card" style={{ borderColor: 'var(--credit)', marginBottom: '1rem' }}>
          <p style={{ margin: 0 }}>
            تمّت فاتورة رقم <strong>{lastInvoiceNo}</strong> بنجاح.{' '}
            <a href="#" onClick={(e) => { e.preventDefault(); nav(`/sales-invoices`); }}>عرض قائمة الفواتير ›</a>
          </p>
        </div>
      )}

      <div className="row" style={{ alignItems: 'stretch', gap: '1rem', flexWrap: 'wrap' }}>
        <div style={{ flex: '2 1 420px', minWidth: 0 }}>
          <div className="row" style={{ marginBottom: '0.75rem' }}>
            <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="بحث برمز الصنف أو اسمه…" style={{ maxWidth: 280 }} />
            <select value={categoryId} onChange={(e) => setCategoryId(e.target.value)} style={{ maxWidth: 220 }}>
              <option value="">كل التصنيفات</option>
              {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
            </select>
          </div>
          {!settings.warehouseId && <p className="muted">اختر المستودع من "إعدادات الجلسة" فوق.</p>}
          {settings.warehouseId && items && items.length === 0 && <p className="muted">ما في صنف مطابق.</p>}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(130px, 1fr))', gap: '0.6rem' }}>
            {items?.map((it) => {
              const onHand = onHandOf(it);
              return (
                <button key={it.id} className="card" style={{ textAlign: 'right', display: 'flex', flexDirection: 'column', gap: '0.4rem', padding: '0.75rem' }} onClick={() => addToCart(it)}>
                  <span className="mono muted" style={{ fontSize: '0.75rem' }}>{it.code}</span>
                  <span style={{ fontWeight: 600, fontSize: '0.9rem' }}>{it.name_ar}</span>
                  <span className="mono" style={{ marginTop: 'auto', fontWeight: 600 }}>{fmtMoney(it.sales_price)}</span>
                  <span className={onHand > 0 ? 'muted' : 'error'} style={{ fontSize: '0.75rem' }}>متوفر: {fmtMoney(onHand)}</span>
                </button>
              );
            })}
          </div>
        </div>

        <div className="card" style={{ flex: '1 1 320px', minWidth: 300, display: 'flex', flexDirection: 'column' }}>
          <h2 style={{ fontSize: '1rem' }}>السلة</h2>
          {cart.length === 0 && <p className="muted">اضغط على صنف لإضافته.</p>}
          {cart.map((l) => (
            <div key={l.itemId} className="row" style={{ borderBottom: '1px solid var(--line)', padding: '0.5rem 0' }}>
              <div className="grow">
                <div style={{ fontSize: '0.88rem', fontWeight: 500 }}>{l.name}</div>
                {l.onHand !== null && l.qty > l.onHand && <div className="error" style={{ fontSize: '0.75rem' }}>أكتر من المتوفر ({fmtMoney(l.onHand)})</div>}
              </div>
              <button onClick={() => changeQty(l.itemId, -1)}>−</button>
              <span className="mono" style={{ minWidth: '1.4rem', textAlign: 'center' }}>{l.qty}</span>
              <button onClick={() => changeQty(l.itemId, 1)}>+</button>
              <span className="mono" style={{ minWidth: '4rem', textAlign: 'left' }}>{fmtMoney(l.unitPrice * l.qty)}</span>
              <button className="btn-danger" onClick={() => removeLine(l.itemId)}>×</button>
            </div>
          ))}

          <div style={{ marginTop: '0.75rem' }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">قبل الضريبة</span><span className="mono">{fmtMoney(totals.subtotal)}</span></div>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">ضريبة 16%</span><span className="mono">{fmtMoney(totals.vat)}</span></div>
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700, fontSize: '1.1rem' }}><span>الإجمالي</span><span className="mono">{fmtMoney(totals.grand)}</span></div>
          </div>

          <div className="row" style={{ marginTop: '0.75rem' }}>
            <button style={{ flex: 1 }} className={paymentType === 'cash' ? 'btn-primary' : ''} onClick={() => setPaymentType('cash')}>فوري</button>
            <button style={{ flex: 1 }} className={paymentType === 'credit' ? 'btn-primary' : ''} onClick={() => setPaymentType('credit')}>آجل</button>
          </div>
          {paymentType === 'cash' && (
            <div className="field" style={{ marginTop: '0.5rem' }}>
              <label>الصندوق</label>
              <select value={settings.cashAccountId} onChange={(e) => setSettings((s) => ({ ...s, cashAccountId: e.target.value }))}>
                <option value="">اختر صندوق المبيعات…</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            </div>
          )}
          <div className="field" style={{ marginTop: '0.5rem' }}>
            <label>{paymentType === 'cash' ? 'الزبون (اختياري — افتراضياً زبون نقدي عام)' : 'الزبون'}</label>
            <select value={dealerId} onChange={(e) => setDealerId(e.target.value)}>
              <option value="">{paymentType === 'cash' ? 'زبون نقدي عام (بدون تحديد)' : '— اختر زبوناً —'}</option>
              {customers?.filter((c) => c.id !== walkinDealer?.id).map((c) => (
                <option key={c.id} value={c.id}>{c.name_ar}</option>
              ))}
            </select>
            {paymentType === 'cash' && (
              <p className="muted" style={{ fontSize: '0.78rem', marginTop: '0.25rem' }}>
                اتركه فاضي لبيع نقدي عادي، أو اختر زبوناً مسجّلاً إذا بدك تنسب هاي الفاتورة إله مع إنو دفع فوري.
              </p>
            )}
          </div>

          {err && <p className="error">{err}</p>}
          <button className="btn-primary" disabled={busy || cart.length === 0} onClick={checkout} style={{ marginTop: '0.75rem' }}>
            إتمام البيع
          </button>
        </div>
      </div>
    </>
  );
}
