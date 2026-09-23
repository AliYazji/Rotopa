import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';
import { AccountSelect, type AccOpt } from '../components/AccountSelect.tsx';

interface OrgRow { id: string; code: string; name_ar: string; fiscal_year_start_month: number; }
interface PrintSettings { address: string; phone: string; footer_note: string; }
interface TaxSettings { enabled: boolean; rate: number; }
interface DefaultAccountsRow { sales_account_id: string | null; output_vat_account_id: string | null; input_vat_account_id: string | null; cash_account_id: string | null; purchase_variance_account_id: string | null; }

const MONTHS = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];

const UNCATEGORIZED = 'غير مصنّف';

export default function Settings() {
  const { org, refetch, refetchTax, refetchDefaultAccounts, refetchPosRegisters } = useOrg();
  const qc = useQueryClient();
  const [nameAr, setNameAr] = useState('');
  const [address, setAddress] = useState('');
  const [phone, setPhone] = useState('');
  const [footerNote, setFooterNote] = useState('');
  const [taxEnabled, setTaxEnabled] = useState(true);
  const [taxRatePct, setTaxRatePct] = useState('16');
  const [defSalesAccountId, setDefSalesAccountId] = useState('');
  const [defOutputVatAccountId, setDefOutputVatAccountId] = useState('');
  const [defInputVatAccountId, setDefInputVatAccountId] = useState('');
  const [defCashAccountId, setDefCashAccountId] = useState('');
  const [defVarianceAccountId, setDefVarianceAccountId] = useState('');
  const [posRegisters, setPosRegisters] = useState<Set<string>>(new Set());
  const [err, setErr] = useState<string | null>(null);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: orgRow } = useQuery({
    queryKey: ['org-basic', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<OrgRow> => {
      const { data, error } = await supabase.from('organizations').select('id, code, name_ar, fiscal_year_start_month').eq('id', org!.id).single();
      if (error) throw error;
      return data as OrgRow;
    },
  });

  const { data: printSettings } = useQuery({
    queryKey: ['org-print-settings', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<PrintSettings | null> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'print').maybeSingle();
      if (error) throw error;
      return (data?.value as PrintSettings) ?? null;
    },
  });

  const { data: taxSettings } = useQuery({
    queryKey: ['org-tax-settings-page', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<TaxSettings | null> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'tax').maybeSingle();
      if (error) throw error;
      return (data?.value as TaxSettings) ?? null;
    },
  });

  const { data: defaultAccountsRow } = useQuery({
    queryKey: ['org-default-accounts-page', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<DefaultAccountsRow | null> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'default_accounts').maybeSingle();
      if (error) throw error;
      return (data?.value as DefaultAccountsRow) ?? null;
    },
  });

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts-grouped-settings', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts')
        .select('id, code, name_ar, category_id, account_categories(name_ar)')
        .eq('is_postable', true).order('code');
      if (error) throw error;
      return data as unknown as AccOpt[];
    },
  });

  const { data: posRegistersRow } = useQuery({
    queryKey: ['org-pos-registers-page', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<string[]> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'pos_registers').maybeSingle();
      if (error) throw error;
      const v = (data?.value ?? {}) as { account_ids?: string[] };
      return v.account_ids ?? [];
    },
  });

  useEffect(() => { if (orgRow) setNameAr(orgRow.name_ar); }, [orgRow]);
  useEffect(() => {
    if (printSettings) {
      setAddress(printSettings.address ?? '');
      setPhone(printSettings.phone ?? '');
      setFooterNote(printSettings.footer_note ?? '');
    }
  }, [printSettings]);
  useEffect(() => {
    if (taxSettings) {
      setTaxEnabled(taxSettings.enabled);
      setTaxRatePct(String(taxSettings.rate * 100));
    }
  }, [taxSettings]);
  useEffect(() => {
    if (defaultAccountsRow) {
      setDefSalesAccountId(defaultAccountsRow.sales_account_id ?? '');
      setDefOutputVatAccountId(defaultAccountsRow.output_vat_account_id ?? '');
      setDefInputVatAccountId(defaultAccountsRow.input_vat_account_id ?? '');
      setDefCashAccountId(defaultAccountsRow.cash_account_id ?? '');
      setDefVarianceAccountId(defaultAccountsRow.purchase_variance_account_id ?? '');
    }
  }, [defaultAccountsRow]);
  useEffect(() => { if (posRegistersRow) setPosRegisters(new Set(posRegistersRow)); }, [posRegistersRow]);

  async function saveOrgName() {
    setErr(null); setSavedMsg(null); setBusy(true);
    const { error } = await supabase.from('organizations').update({ name_ar: nameAr }).eq('id', org!.id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setSavedMsg('تم الحفظ');
    refetch();
    qc.invalidateQueries({ queryKey: ['org-basic', org?.id] });
  }

  async function savePrintSettings() {
    setErr(null); setSavedMsg(null); setBusy(true);
    const { error } = await supabase.from('org_settings').upsert({
      org_id: org!.id, key: 'print', value: { address, phone, footer_note: footerNote },
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setSavedMsg('تم الحفظ');
    qc.invalidateQueries({ queryKey: ['org-print-settings', org?.id] });
  }

  async function saveTaxSettings() {
    setErr(null); setSavedMsg(null);
    const rate = Number(taxRatePct) / 100;
    if (!Number.isFinite(rate) || rate < 0 || rate > 1) return setErr('نسبة الضريبة يجب أن تكون رقمًا بين 0 و100');
    setBusy(true);
    const { error } = await supabase.from('org_settings').upsert({
      org_id: org!.id, key: 'tax', value: { enabled: taxEnabled, rate },
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setSavedMsg('تم الحفظ');
    qc.invalidateQueries({ queryKey: ['org-tax-settings-page', org?.id] });
    refetchTax();
  }

  async function saveDefaultAccounts() {
    setErr(null); setSavedMsg(null); setBusy(true);
    const { error } = await supabase.from('org_settings').upsert({
      org_id: org!.id, key: 'default_accounts', value: {
        sales_account_id: defSalesAccountId || null,
        output_vat_account_id: defOutputVatAccountId || null,
        input_vat_account_id: defInputVatAccountId || null,
        cash_account_id: defCashAccountId || null,
        purchase_variance_account_id: defVarianceAccountId || null,
      },
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setSavedMsg('تم الحفظ');
    qc.invalidateQueries({ queryKey: ['org-default-accounts-page', org?.id] });
    refetchDefaultAccounts();
  }

  function toggleRegister(id: string) {
    setPosRegisters((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  async function savePosRegisters() {
    setErr(null); setSavedMsg(null); setBusy(true);
    const { error } = await supabase.from('org_settings').upsert({
      org_id: org!.id, key: 'pos_registers', value: { account_ids: [...posRegisters] },
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    setSavedMsg('تم الحفظ');
    qc.invalidateQueries({ queryKey: ['org-pos-registers-page', org?.id] });
    refetchPosRegisters();
  }

  return (
    <>
      <h1>إعدادات المؤسسة</h1>
      {err && <p className="error">{err}</p>}
      {savedMsg && <p className="muted">{savedMsg}</p>}

      <div className="card" style={{ maxWidth: 480 }}>
        <h2>البيانات الأساسية</h2>
        <div className="field">
          <label>اسم المؤسسة</label>
          <input value={nameAr} onChange={(e) => setNameAr(e.target.value)} />
        </div>
        <div className="row" style={{ fontSize: '0.85rem' }}>
          <span className="muted">الرمز: <span className="mono">{orgRow?.code}</span> (ثابت)</span>
          <span className="muted">بداية السنة المالية: {orgRow ? MONTHS[orgRow.fiscal_year_start_month - 1] : ''} (ثابت)</span>
        </div>
        <button className="btn-primary" disabled={busy || !nameAr.trim()} onClick={saveOrgName} style={{ marginTop: '0.75rem' }}>حفظ</button>
      </div>

      <div className="card" style={{ maxWidth: 480, marginTop: '1rem' }}>
        <h2>بيانات الطباعة</h2>
        <p className="muted" style={{ fontSize: '0.85rem', marginTop: 0 }}>تظهر بترويسة كل فاتورة مطبوعة.</p>
        <div className="field">
          <label>العنوان</label>
          <input value={address} onChange={(e) => setAddress(e.target.value)} placeholder="المدينة، الشارع" />
        </div>
        <div className="field">
          <label>الهاتف</label>
          <input value={phone} onChange={(e) => setPhone(e.target.value)} dir="ltr" />
        </div>
        <div className="field">
          <label>ملاحظة أسفل الفاتورة (اختياري)</label>
          <input value={footerNote} onChange={(e) => setFooterNote(e.target.value)} placeholder="شكراً لتعاملكم معنا" />
        </div>
        <button className="btn-primary" disabled={busy} onClick={savePrintSettings}>حفظ</button>
      </div>

      <div className="card" style={{ maxWidth: 480, marginTop: '1rem' }}>
        <h2>الضريبة</h2>
        <p className="muted" style={{ fontSize: '0.85rem', marginTop: 0 }}>
          عند تعطيل الضريبة لا تُحسب أو تُطبع على أي فاتورة، ولا يُطلب اختيار حساب ضريبة عند الترحيل.
        </p>
        <div className="field" style={{ flexDirection: 'row', alignItems: 'center', gap: '0.5rem' }}>
          <input type="checkbox" id="tax-enabled" checked={taxEnabled} onChange={(e) => setTaxEnabled(e.target.checked)} />
          <label htmlFor="tax-enabled" style={{ margin: 0 }}>تفعيل الضريبة</label>
        </div>
        <div className="field">
          <label>نسبة الضريبة (%)</label>
          <input
            type="number" min={0} max={100} step="0.01" dir="ltr"
            value={taxRatePct} onChange={(e) => setTaxRatePct(e.target.value)}
            disabled={!taxEnabled}
          />
        </div>
        <button className="btn-primary" disabled={busy} onClick={saveTaxSettings}>حفظ</button>
      </div>

      <div className="card" style={{ maxWidth: 480, marginTop: '1rem' }}>
        <h2>الحسابات الافتراضية</h2>
        <p className="muted" style={{ fontSize: '0.85rem', marginTop: 0 }}>
          تُستخدم كبداية جاهزة عند ترحيل أي فاتورة/مرجع بدل اختيار الحساب من جديد كل مرة —
          يمكن دائماً تغييرها لمستند معيّن عند الحاجة.
        </p>
        <div className="field">
          <label>حساب المبيعات الافتراضي (لصنف بلا حساب خاص)</label>
          <AccountSelect accounts={accounts} value={defSalesAccountId} placeholder="—" onChange={setDefSalesAccountId} />
        </div>
        <div className="field">
          <label>حساب ضريبة المخرجات (المبيعات)</label>
          <AccountSelect accounts={accounts} value={defOutputVatAccountId} placeholder="—" onChange={setDefOutputVatAccountId} />
        </div>
        <div className="field">
          <label>حساب ضريبة المدخلات (المشتريات)</label>
          <AccountSelect accounts={accounts} value={defInputVatAccountId} placeholder="—" onChange={setDefInputVatAccountId} />
        </div>
        <div className="field">
          <label>الصندوق/البنك الافتراضي (للبيع والشراء النقدي)</label>
          <AccountSelect accounts={accounts} value={defCashAccountId} placeholder="—" onChange={setDefCashAccountId} />
        </div>
        <div className="field">
          <label>حساب فروقات أسعار المشتريات وتقييم المخزون</label>
          <p className="muted" style={{ fontSize: '0.8rem', marginTop: 0 }}>
            على عكس ما فوق، هذا الحساب <strong>ثابت</strong> ولا يمكن اختيار حساب آخر عند ترحيل مرجع مشتريات
            بعينه — يُستخدم فقط في الحالة النادرة التي يتعذّر فيها استيعاب فرق تقييم داخل المخزون بأمان.
          </p>
          <AccountSelect accounts={accounts} value={defVarianceAccountId} placeholder="—" onChange={setDefVarianceAccountId} />
        </div>
        <button className="btn-primary" disabled={busy} onClick={saveDefaultAccounts}>حفظ</button>
      </div>

      <div className="card" style={{ maxWidth: 480, marginTop: '1rem' }}>
        <h2>صناديق الكاشير</h2>
        <p className="muted" style={{ fontSize: '0.85rem', marginTop: 0 }}>
          حدد الحسابات يلي فعلاً صناديق بيع — قائمة "الصندوق" بالكاشير بتعرض هاي بس بدل كل
          حسابات دليل الحسابات. اترك القائمة فاضية لعرض كل الحسابات كما كانت.
        </p>
        <div style={{ maxHeight: 280, overflowY: 'auto', border: '1px solid var(--line)', borderRadius: 6, padding: '0.5rem' }}>
          {Object.entries(
            (accounts ?? []).reduce<Record<string, AccOpt[]>>((groups, a) => {
              const label = a.account_categories?.name_ar ?? UNCATEGORIZED;
              (groups[label] ??= []).push(a);
              return groups;
            }, {})
          ).map(([label, rows]) => (
            <div key={label} style={{ marginBottom: '0.5rem' }}>
              <div className="muted" style={{ fontSize: '0.78rem', fontWeight: 600 }}>{label}</div>
              {rows.map((a) => (
                <label key={a.id} style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', width: 'auto', margin: '0.2rem 0', fontSize: '0.85rem' }}>
                  <input type="checkbox" style={{ width: 'auto' }} checked={posRegisters.has(a.id)} onChange={() => toggleRegister(a.id)} />
                  {a.code} · {a.name_ar}
                </label>
              ))}
            </div>
          ))}
        </div>
        <button className="btn-primary" disabled={busy} onClick={savePosRegisters} style={{ marginTop: '0.5rem' }}>حفظ</button>
      </div>
    </>
  );
}
