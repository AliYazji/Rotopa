import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useAuth } from '../lib/auth.tsx';

export default function Onboarding() {
  const { signOut } = useAuth();
  const qc = useQueryClient();
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [currCode, setCurrCode] = useState('NIS');
  const [currName, setCurrName] = useState('شيكل');
  const [startMonth, setStartMonth] = useState(1);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setBusy(true);
    const { error } = await supabase.rpc('create_organization', {
      p_code: code,
      p_name_ar: name,
      p_base_currency_code: currCode,
      p_base_currency_name_ar: currName,
      p_fiscal_year_start_month: startMonth,
    });
    setBusy(false);
    if (error) return setErr(error.message);
    await qc.invalidateQueries({ queryKey: ['my-org'] });
  }

  return (
    <div style={{ display: 'grid', placeItems: 'center', minHeight: '100vh', padding: '1rem' }}>
      <form className="card" onSubmit={create} style={{ width: 420 }}>
        <h1>إنشاء مؤسسة</h1>
        <p className="muted" style={{ marginTop: 0 }}>لست عضواً في أي مؤسسة بعد.</p>
        <div className="row">
          <div className="field grow">
            <label>الرمز</label>
            <input value={code} onChange={(e) => setCode(e.target.value)} required dir="ltr" placeholder="RETAJ" />
          </div>
          <div className="field grow">
            <label>الاسم</label>
            <input value={name} onChange={(e) => setName(e.target.value)} required placeholder="مجموعة رتاج" />
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>رمز عملة الأساس</label>
            <input value={currCode} onChange={(e) => setCurrCode(e.target.value)} required dir="ltr" />
          </div>
          <div className="field grow">
            <label>اسم عملة الأساس</label>
            <input value={currName} onChange={(e) => setCurrName(e.target.value)} required />
          </div>
        </div>
        <div className="field">
          <label>بداية السنة المالية (الشهر)</label>
          <select value={startMonth} onChange={(e) => setStartMonth(Number(e.target.value))}>
            {Array.from({ length: 12 }, (_, i) => (
              <option key={i + 1} value={i + 1}>{i + 1}</option>
            ))}
          </select>
        </div>
        {err && <p className="error">{err}</p>}
        <button className="btn-primary" style={{ width: '100%' }} disabled={busy}>
          {busy ? '…' : 'إنشاء'}
        </button>
        <button type="button" onClick={signOut} style={{ width: '100%', marginTop: '0.5rem', border: 'none', background: 'none' }}>
          تسجيل الخروج
        </button>
      </form>
    </div>
  );
}
