import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';

interface AccOpt { id: string; code: string; name_ar: string; is_postable: boolean; }
interface CatOpt { id: string; name_ar: string; }
interface CurOpt { id: string; code: string; name_ar: string; }

export default function AccountNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [kind, setKind] = useState<'postable' | 'header'>('postable');
  const [parentId, setParentId] = useState('');
  const [nature, setNature] = useState('both');
  const [categoryId, setCategoryId] = useState('');
  const [currencyId, setCurrencyId] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: parents } = useQuery({
    queryKey: ['header-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar, is_postable').eq('is_postable', false).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });
  const { data: categories } = useQuery({
    queryKey: ['account-categories', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<CatOpt[]> => {
      const { data, error } = await supabase.from('account_categories').select('id, name_ar').order('sort_order');
      if (error) throw error;
      return data as CatOpt[];
    },
  });
  const { data: currencies } = useQuery({
    queryKey: ['currencies', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<CurOpt[]> => {
      const { data, error } = await supabase.from('currencies').select('id, code, name_ar').order('is_base', { ascending: false });
      if (error) throw error;
      return data as CurOpt[];
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (!code.trim() || !name.trim()) throw new Error('الرمز والاسم مطلوبان');
      const { error } = await supabase.from('accounts').insert({
        org_id: org!.id,
        code, name_ar: name,
        parent_id: parentId || null,
        is_postable: kind === 'postable',
        nature,
        category_id: categoryId || null,
        currency_id: currencyId || null,
      });
      if (error) throw error;
      nav('/accounts');
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>حساب جديد</h1>
      <div className="card" style={{ maxWidth: 520 }}>
        <div className="row">
          <div className="field" style={{ width: 140 }}>
            <label>الرمز</label>
            <input value={code} onChange={(e) => setCode(e.target.value)} dir="ltr" />
          </div>
          <div className="field grow">
            <label>الاسم</label>
            <input value={name} onChange={(e) => setName(e.target.value)} />
          </div>
        </div>

        <div className="field">
          <label>النوع</label>
          <div className="row" style={{ gap: '1.25rem' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={kind === 'postable'} onChange={() => setKind('postable')} /> حساب ترحيل (ورقة)
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="radio" style={{ width: 'auto' }} checked={kind === 'header'} onChange={() => setKind('header')} /> حساب تجميع (أب)
            </label>
          </div>
        </div>

        <div className="field">
          <label>الحساب الأب (اختياري لحساب جذر)</label>
          <select value={parentId} onChange={(e) => setParentId(e.target.value)}>
            <option value="">— بلا أب (جذر) —</option>
            {parents?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>

        <div className="row">
          <div className="field grow">
            <label>الطبيعة</label>
            <select value={nature} onChange={(e) => setNature(e.target.value)}>
              <option value="debit">مدين</option>
              <option value="credit">دائن</option>
              <option value="both">مدين/دائن</option>
            </select>
          </div>
          <div className="field grow">
            <label>التصنيف (للقوائم المالية)</label>
            <select value={categoryId} onChange={(e) => setCategoryId(e.target.value)}>
              <option value="">—</option>
              {categories?.map((c) => <option key={c.id} value={c.id}>{c.name_ar}</option>)}
            </select>
          </div>
          <div className="field grow">
            <label>عملة مقيّدة (اختياري)</label>
            <select value={currencyId} onChange={(e) => setCurrencyId(e.target.value)}>
              <option value="">أي عملة</option>
              {currencies?.map((c) => <option key={c.id} value={c.id}>{c.code} · {c.name_ar}</option>)}
            </select>
          </div>
        </div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>حفظ</button>
      </div>
    </>
  );
}
