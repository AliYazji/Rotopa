import { useState } from 'react';
import { supabase } from '../lib/supabase.ts';

export default function Login() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setBusy(true);
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
          {mode === 'signin' ? 'تسجيل الدخول' : 'إنشاء حساب'}
        </p>
        <div className="field">
          <label>البريد الإلكتروني</label>
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required dir="ltr" />
        </div>
        <div className="field">
          <label>كلمة المرور</label>
          <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required dir="ltr" />
        </div>
        {err && <p className="error">{err}</p>}
        <button className="btn-primary" style={{ width: '100%' }} disabled={busy}>
          {busy ? '…' : mode === 'signin' ? 'دخول' : 'تسجيل'}
        </button>
        <button
          type="button"
          onClick={() => setMode(mode === 'signin' ? 'signup' : 'signin')}
          style={{ width: '100%', marginTop: '0.5rem', border: 'none', background: 'none', color: 'var(--accent)' }}
        >
          {mode === 'signin' ? 'ليس لديك حساب؟ إنشاء حساب' : 'لديك حساب؟ تسجيل الدخول'}
        </button>
      </form>
    </div>
  );
}
