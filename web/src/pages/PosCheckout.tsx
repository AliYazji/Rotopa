import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtMoney, fmtPct, sanitizeSearchTerm, today, translateError } from '../lib/format.ts';
import { AccountSelect, type AccOpt } from '../components/AccountSelect.tsx';
import type { ItemUnitOpt } from '../components/ItemPicker.tsx';

interface WhOpt { id: string; code: string; name_ar: string; }
interface CatOpt { id: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; }
interface ItemHit {
  id: string; code: string; name_ar: string; sales_price: number; base_unit_name: string; category_id: string | null;
  is_composite: boolean;
  item_warehouse_balances: { qty: number; avg_cost: number | null; warehouse_id: string }[];
  item_units: ItemUnitOpt[];
}
interface CartLine {
  itemId: string; code: string; name: string; unitPrice: string; baseUnitName: string; qty: number; onHand: number | null;
  units: ItemUnitOpt[]; unitId: string; discountPct: string; discountMode: 'pct' | 'amount'; avgCost: number | null;
}

const WALKIN_CODE = 'CASH-WALKIN';
const UNCATEGORIZED = 'غير مصنّف';
const SETTINGS_KEYS = ['warehouseId', 'vatAccountId', 'defaultSalesAccountId', 'cashAccountId'] as const;
type Settings = Record<(typeof SETTINGS_KEYS)[number], string>;
const emptySettings: Settings = { warehouseId: '', vatAccountId: '', defaultSalesAccountId: '', cashAccountId: '' };

const OPTIONAL_COLUMNS = [
  { key: 'unit', label: 'الوحدة' },
  { key: 'discount', label: 'الخصم' },
  { key: 'cost', label: 'التكلفة' },
  { key: 'profit', label: 'الربح' },
] as const;
type ColumnKey = (typeof OPTIONAL_COLUMNS)[number]['key'];
type ColumnVisibility = Record<ColumnKey, boolean>;
const defaultColumns: ColumnVisibility = { unit: false, discount: false, cost: false, profit: false };

/** qty/price are always entered in terms of the chosen unit — the RPC does
 * any base-unit conversion server-side, same convention as SalesInvoiceNew */
function lineFactor(l: CartLine) {
  return l.units.find((u) => u.id === l.unitId)?.conversion_factor ?? 1;
}
/** a fixed-amount discount is converted to the equivalent percentage before
 * submission, since the database only stores discount_pct */
function effectiveDiscountPct(l: CartLine) {
  const qty = l.qty, price = parseFloat(l.unitPrice) || 0;
  const raw = parseFloat(l.discountPct) || 0;
  if (l.discountMode === 'pct') return Math.min(100, Math.max(0, raw));
  const gross = qty * price;
  return gross > 0 ? Math.min(100, Math.max(0, (raw / gross) * 100)) : 0;
}
function lineTotal(l: CartLine) {
  const qty = l.qty, price = parseFloat(l.unitPrice) || 0;
  return qty * price * (1 - effectiveDiscountPct(l) / 100);
}

export default function PosCheckout() {
  const { org, taxRate, taxEnabled, defaultAccounts, posRegisterIds } = useOrg();
  const nav = useNavigate();
  const qc = useQueryClient();

  const [settings, setSettings] = useState<Settings>(emptySettings);
  const [showSettings, setShowSettings] = useState(false);
  const [columns, setColumns] = useState<ColumnVisibility>(defaultColumns);
  const [showColumnMenu, setShowColumnMenu] = useState(false);
  const [search, setSearch] = useState('');
  const [categoryId, setCategoryId] = useState('');
  const [cart, setCart] = useState<CartLine[]>([]);
  const [invoiceDate, setInvoiceDate] = useState(today());
  const [notes, setNotes] = useState('');
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
      const rawCols = localStorage.getItem(`pos-columns-${org.id}`);
      if (rawCols) setColumns({ ...defaultColumns, ...JSON.parse(rawCols) });
    } catch { /* ignore malformed/blocked storage */ }
  }, [org]);
  useEffect(() => {
    if (!org) return;
    try { localStorage.setItem(`pos-settings-${org.id}`, JSON.stringify(settings)); } catch { /* ignore */ }
  }, [org, settings]);
  useEffect(() => {
    if (!org) return;
    try { localStorage.setItem(`pos-columns-${org.id}`, JSON.stringify(columns)); } catch { /* ignore */ }
  }, [org, columns]);

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
  // org-level default accounts (Settings > الحسابات الافتراضية) fill in
  // whatever a saved localStorage session didn't already have — a fresh
  // device/browser now starts pre-filled instead of blank every time
  useEffect(() => {
    setSettings((s) => ({
      ...s,
      vatAccountId: s.vatAccountId || defaultAccounts.outputVatAccountId,
      defaultSalesAccountId: s.defaultSalesAccountId || defaultAccounts.salesAccountId,
      cashAccountId: s.cashAccountId || defaultAccounts.cashAccountId,
    }));
  }, [defaultAccounts]);
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts-grouped', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts')
        .select('id, code, name_ar, category_id, account_categories(name_ar)')
        .eq('is_postable', true).order('code');
      if (error) throw error; return data as unknown as AccOpt[];
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
  // document_sequences.next_value is directly readable by any org member —
  // this is only a PREVIEW of the number the next invoice will get (another
  // sale on another till could grab it first), not a reservation
  const { data: nextInvoiceNo } = useQuery({
    queryKey: ['next-sales-invoice-no', org?.id, lastInvoiceNo], enabled: !!org,
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.from('document_sequences').select('next_value')
        .eq('org_id', org!.id).eq('key', 'sales_invoice').maybeSingle();
      if (error) throw error;
      return Number(data?.next_value ?? 1);
    },
  });
  // if a shift is currently open on the chosen cash drawer, link every cash
  // sale to it automatically (so the print layout can show who was
  // cashiering) — entirely optional, a cash sale posts exactly the same
  // with no open shift at all
  const { data: openShift } = useQuery({
    queryKey: ['open-cash-shift', org?.id, settings.cashAccountId, lastInvoiceNo],
    enabled: !!org && !!settings.cashAccountId,
    queryFn: async (): Promise<{ id: string; shift_no: number; cashier: { name_ar: string } | null } | null> => {
      const { data, error } = await supabase.from('cash_shifts')
        .select('id, shift_no, cashier:cashier_dealer_id(name_ar)')
        .eq('org_id', org!.id).eq('cash_account_id', settings.cashAccountId).eq('status', 'open').maybeSingle();
      if (error) throw error;
      return data as unknown as { id: string; shift_no: number; cashier: { name_ar: string } | null } | null;
    },
  });

  const term = sanitizeSearchTerm(search);
  const { data: items } = useQuery({
    queryKey: ['pos-items', org?.id, term, categoryId, settings.warehouseId],
    enabled: !!org && !!settings.warehouseId,
    queryFn: async (): Promise<ItemHit[]> => {
      let q = supabase.from('items')
        .select('id, code, name_ar, sales_price, base_unit_name, category_id, is_composite, item_warehouse_balances(qty, avg_cost, warehouse_id), item_units(id, unit_name, conversion_factor, is_sales_default, is_purchase_default)')
        .eq('is_active', true).or('is_stock_tracked.eq.true,is_composite.eq.true').order('name_ar').limit(40);
      // no search/category chosen yet -> a default browse list (capped at
      // 40) instead of an empty grid; typing, scanning a barcode, or picking
      // a category narrows it
      if (term.length >= 2) q = q.or(`name_ar.ilike.%${term}%,code.ilike.%${term}%,barcode.ilike.%${term}%`);
      if (categoryId) q = q.eq('category_id', categoryId);
      const { data, error } = await q;
      if (error) throw error;
      return data as unknown as ItemHit[];
    },
  });

  const itemGroups = useMemo(() => {
    const nameById = new Map((categories ?? []).map((c) => [c.id, c.name_ar]));
    const order: string[] = [];
    const groups = new Map<string, { label: string; rows: ItemHit[] }>();
    for (const it of items ?? []) {
      const key = it.category_id ?? 'none';
      const label = it.category_id ? (nameById.get(it.category_id) ?? UNCATEGORIZED) : UNCATEGORIZED;
      if (!groups.has(key)) { groups.set(key, { label, rows: [] }); order.push(key); }
      groups.get(key)!.rows.push(it);
    }
    return order.map((key) => groups.get(key)!);
  }, [items, categories]);

  function balanceOf(hit: ItemHit) {
    return hit.item_warehouse_balances.find((b) => b.warehouse_id === settings.warehouseId);
  }

  // Settings > صناديق الكاشير curates this down to just the org's real
  // sales registers instead of the whole (now 285-account) chart — an
  // empty curated list means "not set up yet", so show everything
  const cashRegisterOptions = useMemo(() => {
    if (!accounts || posRegisterIds.length === 0) return accounts;
    const allowed = new Set(posRegisterIds);
    return accounts.filter((a) => allowed.has(a.id));
  }, [accounts, posRegisterIds]);

  const totals = useMemo(() => {
    const subtotal = cart.reduce((s, l) => s + lineTotal(l), 0);
    const vat = subtotal * taxRate;
    const profit = cart.reduce((s, l) => {
      if (l.avgCost == null) return s;
      const cost = l.qty * lineFactor(l) * l.avgCost;
      return s + (lineTotal(l) - cost);
    }, 0);
    return { subtotal, vat, grand: subtotal + vat, profit };
  }, [cart, taxRate]);
  const overStockLine = cart.find((l) => l.onHand !== null && l.qty * lineFactor(l) > l.onHand!);

  function addToCart(hit: ItemHit) {
    setCart((ls) => {
      const existing = ls.find((l) => l.itemId === hit.id);
      if (existing) return ls.map((l) => (l.itemId === hit.id ? { ...l, qty: l.qty + 1 } : l));
      const balance = balanceOf(hit);
      const defaultUnit = hit.item_units.find((u) => u.is_sales_default);
      // a composite item has no stock balance of its own — its real
      // availability depends on its recipe's components, which
      // post_sales_invoice checks server-side; null means "not tracked
      // here", never "zero"
      return [...ls, {
        itemId: hit.id, code: hit.code, name: hit.name_ar, unitPrice: String(hit.sales_price),
        baseUnitName: hit.base_unit_name, qty: 1, onHand: hit.is_composite ? null : (balance ? Number(balance.qty) : 0),
        units: hit.item_units ?? [], unitId: defaultUnit?.id ?? '',
        discountPct: '0', discountMode: 'pct', avgCost: balance?.avg_cost != null ? Number(balance.avg_cost) : null,
      }];
    });
  }
  function changeQty(itemId: string, delta: number) {
    setCart((ls) => ls.flatMap((l) => {
      if (l.itemId !== itemId) return [l];
      const qty = l.qty + delta;
      return qty <= 0 ? [] : [{ ...l, qty }];
    }));
  }
  function setLine(itemId: string, patch: Partial<CartLine>) {
    setCart((ls) => ls.map((l) => (l.itemId === itemId ? { ...l, ...patch } : l)));
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
    if (taxEnabled && !settings.vatAccountId) return setErr('اختر حساب ضريبة المخرجات من الإعدادات فوق');
    if (overStockLine) return setErr(`الكمية المطلوبة لصنف "${overStockLine.name}" أكتر من المتوفر (${fmtMoney(overStockLine.onHand)}).`);
    // فوري defaults to the walk-in customer but can be any real customer too
    // (a regular customer paying cash instead of on credit); آجل must be a
    // real, specific customer — crediting the anonymous walk-in makes no sense.
    const effectiveDealerId = dealerId || (paymentType === 'cash' ? walkinDealer?.id : '');
    if (paymentType === 'credit' && (!dealerId || dealerId === walkinDealer?.id)) return setErr('اختر زبوناً مسجّلاً للبيع الآجل');
    if (paymentType === 'cash' && !settings.cashAccountId) return setErr('اختر الصندوق');
    if (paymentType === 'cash' && !openShift) return setErr('لا يمكن إتمام بيع نقدي قبل فتح وردية على الصندوق المختار.');
    if (!effectiveDealerId) return setErr('ما في زبون نقدي عام معرَّف بعد — أنشئه من الإعدادات فوق');

    setBusy(true);
    try {
      const { data: invoiceId, error } = await supabase.rpc('create_sales_invoice', {
        p_org: org!.id, p_invoice_date: invoiceDate, p_dealer_id: effectiveDealerId, p_warehouse_id: settings.warehouseId,
        p_lines: cart.map((l) => ({
          item_id: l.itemId, qty: l.qty, unit_price: parseFloat(l.unitPrice) || 0,
          unit_id: l.unitId || null, discount_pct: effectiveDiscountPct(l),
        })),
        p_payment_method: paymentType, p_cash_account_id: paymentType === 'cash' ? settings.cashAccountId : null,
        p_description: notes || '', p_cash_shift_id: paymentType === 'cash' ? (openShift?.id ?? null) : null,
      });
      if (error) throw error;

      const { error: pErr } = await supabase.rpc('post_sales_invoice', {
        p_invoice_id: invoiceId, p_default_sales_account_id: settings.defaultSalesAccountId || null,
        p_output_vat_account_id: taxEnabled ? settings.vatAccountId : null,
      });
      if (pErr) throw pErr;

      const { data: inv } = await supabase.from('sales_invoices').select('invoice_no').eq('id', invoiceId).single();
      setLastInvoiceNo(inv?.invoice_no ?? null);
      setCart([]); setDealerId(''); setNotes(''); setInvoiceDate(today());
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
            {taxEnabled && (
              <div className="field grow">
                <label>حساب ضريبة المخرجات</label>
                <AccountSelect accounts={accounts} value={settings.vatAccountId} placeholder="—"
                  onChange={(v) => setSettings((s) => ({ ...s, vatAccountId: v }))} />
              </div>
            )}
            <div className="field grow">
              <label>حساب المبيعات الافتراضي (لصنف بلا حساب خاص)</label>
              <AccountSelect accounts={accounts} value={settings.defaultSalesAccountId} placeholder="—"
                onChange={(v) => setSettings((s) => ({ ...s, defaultSalesAccountId: v }))} />
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
            <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="بحث برمز الصنف أو اسمه أو الباركود…" style={{ maxWidth: 280 }} />
            <select value={categoryId} onChange={(e) => setCategoryId(e.target.value)} style={{ maxWidth: 220 }}>
              <option value="">كل التصنيفات</option>
              {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
            </select>
          </div>
          {!settings.warehouseId && <p className="muted">اختر المستودع من "إعدادات الجلسة" فوق.</p>}
          {settings.warehouseId && items && items.length === 0 && <p className="muted">ما في صنف مطابق.</p>}
          {itemGroups.map((g) => (
            <div key={g.label} style={{ marginBottom: '1rem' }}>
              <h2 style={{ fontSize: '0.85rem', color: 'var(--muted)', margin: '0 0 0.4rem' }}>{g.label}</h2>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(130px, 1fr))', gap: '0.6rem' }}>
                {g.rows.map((it) => {
                  const onHand = it.is_composite ? null : Number(balanceOf(it)?.qty ?? 0);
                  return (
                    <button key={it.id} className="card" style={{ textAlign: 'right', display: 'flex', flexDirection: 'column', gap: '0.4rem', padding: '0.75rem' }} onClick={() => addToCart(it)}>
                      <span className="mono muted" style={{ fontSize: '0.75rem' }}>{it.code}</span>
                      <span style={{ fontWeight: 600, fontSize: '0.9rem' }}>{it.name_ar}</span>
                      <span className="mono" style={{ marginTop: 'auto', fontWeight: 600 }}>{fmtMoney(it.sales_price)}</span>
                      {onHand === null
                        ? <span className="muted" style={{ fontSize: '0.75rem' }}>صنف مركّب — التوفر حسب المكونات</span>
                        : <span className={onHand > 0 ? 'muted' : 'error'} style={{ fontSize: '0.75rem' }}>متوفر: {fmtMoney(onHand)}</span>}
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>

        <div className="card" style={{ flex: '1 1 460px', minWidth: 320, display: 'flex', flexDirection: 'column' }}>
          <div className="row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
            <h2 style={{ fontSize: '1rem', margin: 0 }}>السلة</h2>
            <span className="muted mono" style={{ fontSize: '0.85rem' }}>فاتورة رقم {nextInvoiceNo ?? '—'} (متوقّع)</span>
          </div>

          <div className="row" style={{ marginTop: '0.5rem' }}>
            <div className="field" style={{ width: 150 }}>
              <label>التاريخ</label>
              <input type="date" value={invoiceDate} onChange={(e) => setInvoiceDate(e.target.value)} />
            </div>
            <div className="field grow">
              <label>{paymentType === 'cash' ? 'الزبون (اختياري — افتراضياً زبون نقدي عام)' : 'الزبون'}</label>
              <select value={dealerId} onChange={(e) => setDealerId(e.target.value)}>
                <option value="">{paymentType === 'cash' ? 'زبون نقدي عام (بدون تحديد)' : '— اختر زبوناً —'}</option>
                {customers?.filter((c) => c.id !== walkinDealer?.id).map((c) => (
                  <option key={c.id} value={c.id}>{c.name_ar}</option>
                ))}
              </select>
            </div>
          </div>

          <div className="row" style={{ marginTop: '0.5rem' }}>
            <button style={{ flex: 1 }} className={paymentType === 'cash' ? 'btn-primary' : ''} onClick={() => setPaymentType('cash')}>فوري</button>
            <button style={{ flex: 1 }} className={paymentType === 'credit' ? 'btn-primary' : ''} onClick={() => setPaymentType('credit')}>آجل</button>
          </div>
          {paymentType === 'cash' && (
            <div className="field" style={{ marginTop: '0.5rem' }}>
              <label>الصندوق</label>
              <AccountSelect accounts={cashRegisterOptions} value={settings.cashAccountId} placeholder="اختر صندوق المبيعات…"
                onChange={(v) => setSettings((s) => ({ ...s, cashAccountId: v }))} />
              {settings.cashAccountId && (
                openShift ? (
                  <p className="muted" style={{ fontSize: '0.78rem', marginTop: '0.25rem' }}>
                    وردية رقم {openShift.shift_no} مفتوحة{openShift.cashier ? ` — الكاشير: ${openShift.cashier.name_ar}` : ''} ·{' '}
                    <Link to={`/cash-shifts/${openShift.id}`}>عرض</Link>
                  </p>
                ) : (
                  <p className="error" style={{ fontSize: '0.78rem', marginTop: '0.25rem' }}>
                    ما في وردية مفتوحة على هذا الصندوق — لازم تُفتح قبل أي بيع نقدي. <Link to="/cash-shifts">فتح وردية ›</Link>
                  </p>
                )
              )}
            </div>
          )}

          <div className="field" style={{ marginTop: '0.5rem' }}>
            <label>ملاحظات (اختياري)</label>
            <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="أي ملاحظة على الفاتورة…" />
          </div>

          <div className="row" style={{ justifyContent: 'space-between', alignItems: 'center', marginTop: '0.75rem', position: 'relative' }}>
            <span className="muted" style={{ fontSize: '0.85rem' }}>الأصناف</span>
            <button onClick={() => setShowColumnMenu((s) => !s)} style={{ fontSize: '0.8rem' }}>⚙ الأعمدة</button>
            {showColumnMenu && (
              <div className="card" style={{ position: 'absolute', zIndex: 10, top: '100%', insetInlineEnd: 0, padding: '0.5rem 0.75rem', minWidth: 160 }}>
                {OPTIONAL_COLUMNS.map((c) => (
                  <label key={c.key} style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', width: 'auto', margin: '0.3rem 0', fontSize: '0.85rem' }}>
                    <input type="checkbox" style={{ width: 'auto' }} checked={columns[c.key]}
                      onChange={(e) => setColumns((cc) => ({ ...cc, [c.key]: e.target.checked }))} />
                    {c.label}
                  </label>
                ))}
              </div>
            )}
          </div>

          {cart.length === 0 && <p className="muted">اضغط على صنف لإضافته.</p>}
          {cart.length > 0 && (
            <div style={{ overflowX: 'auto' }}>
              <table style={{ fontSize: '0.85rem' }}>
                <thead>
                  <tr>
                    <th>الصنف</th>
                    <th className="num" style={{ width: 90 }}>الكمية</th>
                    {columns.unit && <th style={{ width: 100 }}>الوحدة</th>}
                    <th className="num" style={{ width: 85 }}>السعر</th>
                    {columns.discount && <th style={{ width: 110 }}>الخصم</th>}
                    {columns.cost && <th className="num" style={{ width: 85 }}>التكلفة</th>}
                    {columns.profit && <th className="num" style={{ width: 85 }}>الربح</th>}
                    <th className="num" style={{ width: 85 }}>الإجمالي</th>
                    <th style={{ width: 30 }} />
                  </tr>
                </thead>
                <tbody>
                  {cart.map((l) => {
                    const factor = lineFactor(l);
                    const overStock = l.onHand !== null && l.qty * factor > l.onHand;
                    const costTotal = l.avgCost != null ? l.qty * factor * l.avgCost : null;
                    const profit = costTotal != null ? lineTotal(l) - costTotal : null;
                    return (
                      <tr key={l.itemId}>
                        <td>
                          {l.name}
                          {overStock && <div className="error" style={{ fontSize: '0.72rem' }}>أكتر من المتوفر ({fmtMoney(l.onHand)})</div>}
                        </td>
                        <td className="num">
                          <div className="row" style={{ justifyContent: 'center', gap: '0.2rem' }}>
                            <button onClick={() => changeQty(l.itemId, -1)}>−</button>
                            <span className="mono" style={{ minWidth: '1.4rem', textAlign: 'center' }}>{l.qty}</span>
                            <button onClick={() => changeQty(l.itemId, 1)}>+</button>
                          </div>
                        </td>
                        {columns.unit && (
                          <td>
                            <select value={l.unitId} onChange={(e) => setLine(l.itemId, { unitId: e.target.value })} disabled={l.units.length === 0}>
                              <option value="">{l.baseUnitName}</option>
                              {l.units.map((u) => <option key={u.id} value={u.id}>{u.unit_name}</option>)}
                            </select>
                          </td>
                        )}
                        <td className="num">
                          <input className="num" inputMode="decimal" value={l.unitPrice} style={{ width: 70 }}
                            onChange={(e) => setLine(l.itemId, { unitPrice: e.target.value })} />
                        </td>
                        {columns.discount && (
                          <td>
                            <div className="row" style={{ gap: '0.2rem' }}>
                              <input className="num" inputMode="decimal" value={l.discountPct} style={{ width: 55 }}
                                onChange={(e) => setLine(l.itemId, { discountPct: e.target.value })} />
                              <select value={l.discountMode} style={{ width: 55 }}
                                onChange={(e) => setLine(l.itemId, { discountMode: e.target.value as 'pct' | 'amount' })}>
                                <option value="pct">%</option>
                                <option value="amount">مبلغ</option>
                              </select>
                            </div>
                          </td>
                        )}
                        {columns.cost && <td className="num muted">{costTotal != null ? fmtMoney(costTotal) : '—'}</td>}
                        {columns.profit && (
                          <td className="num" style={{ color: profit == null ? undefined : profit >= 0 ? 'var(--credit)' : 'var(--danger)' }}>
                            {profit != null ? fmtMoney(profit) : '—'}
                          </td>
                        )}
                        <td className="num mono">{fmtMoney(lineTotal(l))}</td>
                        <td><button className="btn-danger" onClick={() => removeLine(l.itemId)}>×</button></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}

          <div style={{ marginTop: '0.75rem' }}>
            {taxEnabled && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">قبل الضريبة</span><span className="mono">{fmtMoney(totals.subtotal)}</span></div>}
            {taxEnabled && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">ضريبة {fmtPct(taxRate)}</span><span className="mono">{fmtMoney(totals.vat)}</span></div>}
            {columns.profit && (
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <span className="muted">الربح المتوقّع</span>
                <span className="mono" style={{ color: totals.profit >= 0 ? 'var(--credit)' : 'var(--danger)' }}>{fmtMoney(totals.profit)}</span>
              </div>
            )}
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700, fontSize: '1.1rem' }}><span>الإجمالي</span><span className="mono">{fmtMoney(totals.grand)}</span></div>
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
