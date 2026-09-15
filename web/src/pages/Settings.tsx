import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface OrgRow { id: string; code: string; name_ar: string; fiscal_year_start_month: number; }
interface PrintSettings { address: string; phone: string; footer_note: string; }

const MONTHS = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];

export default function Settings() {
  const { org, refetch } = useOrg();
  const qc = useQueryClient();
  const [nameAr, setNameAr] = useState('');
  const [address, setAddress] = useState('');
  const [phone, setPhone] = useState('');
  const [footerNote, setFooterNote] = useState('');
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

  useEffect(() => { if (orgRow) setNameAr(orgRow.name_ar); }, [orgRow]);
  useEffect(() => {
    if (printSettings) {
      setAddress(printSettings.address ?? '');
      setPhone(printSettings.phone ?? '');
      setFooterNote(printSettings.footer_note ?? '');
    }
  }, [printSettings]);

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
    </>
  );
}
