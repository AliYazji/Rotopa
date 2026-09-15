import { useState } from 'react';
import { supabase } from '../lib/supabase.ts';
import { useAuth } from '../lib/auth.tsx';

export default function Login() {
  const { resetPasswordForEmail } = useAuth();
  const [mode, setMode] = useState<'signin' | 'signup' | 'reset'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setInfo(null);
    setBusy(true);
    if (mode === 'reset') {
      const { error } = await resetPasswordForEmail(email);
      setBusy(false);
      if (error) setErr(error);
      else setInfo('إن كان البريد الإلكتروني مسجلاً لدينا، وصلته رسالة لإعادة تعيين كلمة المرور.');
      return;
    }
    const fn =
      mode === 'signin'
        ? supabase.auth.signInWithPassword({ email, password })
        : supabase.auth.signUp({ email, password });
    const { error } = await fn;
    setBusy(false);
    if (error) setErr(error.message);
  }

  return (
    <div style={{ display: 'grid', placeItems: 'center', minHeight: '100vh', padding: '1rem' }}>
      <form className="card" onSubmit={submit} style={{ width: 340 }}>
        <h1>روتوبا</h1>
        <p className="muted" style={{ marginTop: 0 }}>
          {mode === 'signin' ? 'تسجيل الدخول' : mode === 'signup' ? 'إنشاء حساب' : 'إعادة تعيين كلمة المرور'}
        </p>
        <div className="field">
          <label>البريد الإلكتروني</label>
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required dir="ltr" />
        </div>
        {mode !== 'reset' && (
          <div className="field">
            <label>كلمة المرور</label>
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required dir="ltr" />
          </div>
        )}
        {err && <p className="error">{err}</p>}
        {info && <p className="muted">{info}</p>}
        <button className="btn-primary" style={{ width: '100%' }} disabled={busy}>
          {busy ? '…' : mode === 'signin' ? 'دخول' : mode === 'signup' ? 'تسجيل' : 'إرسال رابط إعادة التعيين'}
        </button>
        {mode !== 'reset' && (
          <button
            type="button"
            onClick={() => { setMode(mode === 'signin' ? 'signup' : 'signin'); setErr(null); setInfo(null); }}
            style={{ width: '100%', marginTop: '0.5rem', border: 'none', background: 'none', color: 'var(--accent)' }}
          >
            {mode === 'signin' ? 'ليس لديك حساب؟ إنشاء حساب' : 'لديك حساب؟ تسجيل الدخول'}
          </button>
        )}
        {mode === 'signin' && (
          <button
            type="button"
            onClick={() => { setMode('reset'); setErr(null); setInfo(null); }}
            style={{ width: '100%', marginTop: '0.25rem', border: 'none', background: 'none', color: 'var(--muted)', fontSize: '0.85rem' }}
          >
            نسيت كلمة المرور؟
          </button>
        )}
        {mode === 'reset' && (
          <button
            type="button"
            onClick={() => { setMode('signin'); setErr(null); setInfo(null); }}
            style={{ width: '100%', marginTop: '0.5rem', border: 'none', background: 'none', color: 'var(--accent)' }}
          >
            رجوع لتسجيل الدخول
          </button>
        )}
      </form>
    </div>
  );
}
