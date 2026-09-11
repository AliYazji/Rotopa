import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { today, translateError } from '../lib/format.ts';

interface AccOpt { id: string; code: string; name_ar: string; }

export default function FixedAssetNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [code, setCode] = useState('');
  const [nameAr, setNameAr] = useState('');
  const [assetAccountId, setAssetAccountId] = useState('');
  const [accumAccountId, setAccumAccountId] = useState('');
  const [depExpAccountId, setDepExpAccountId] = useState('');
  const [creditAccountId, setCreditAccountId] = useState('');
  const [acquisitionDate, setAcquisitionDate] = useState(today());
  const [cost, setCost] = useState('');
  const [salvageValue, setSalvageValue] = useState('0');
  const [usefulLifeMonths, setUsefulLifeMonths] = useState('60');
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (!code.trim()) throw new Error('أدخل رمز الأصل');
      if (!nameAr.trim()) throw new Error('أدخل اسم الأصل');
      if (!assetAccountId) throw new Error('اختر حساب الأصل الثابت');
      if (!accumAccountId) throw new Error('اختر حساب مجمع الإهلاك');
      if (!depExpAccountId) throw new Error('اختر حساب مصروف الإهلاك');
      if (!creditAccountId) throw new Error('اختر الحساب المقابل (الصندوق/البنك أو الذمم)');
      const costNum = parseFloat(cost);
      if (!(costNum > 0)) throw new Error('أدخل تكلفة صحيحة');
      const salvageNum = parseFloat(salvageValue) || 0;
      if (salvageNum > costNum) throw new Error('قيمة الخردة لا يمكن أن تتجاوز التكلفة');
      const lifeNum = parseInt(usefulLifeMonths, 10);
      if (!(lifeNum > 0)) throw new Error('أدخل عمراً إنتاجياً صحيحاً بالأشهر');

      const { data: assetId, error } = await supabase.rpc('register_fixed_asset', {
        p_org: org!.id, p_code: code.trim(), p_name_ar: nameAr.trim(),
        p_asset_account_id: assetAccountId, p_accum_depreciation_account_id: accumAccountId,
        p_depreciation_expense_account_id: depExpAccountId,
        p_acquisition_date: acquisitionDate, p_cost: costNum, p_salvage_value: salvageNum,
        p_useful_life_months: lifeNum, p_credit_account_id: creditAccountId, p_notes: notes,
      });
      if (error) throw error;
      nav(`/fixed-assets/${assetId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>تسجيل أصل ثابت جديد</h1>
      <div className="card" style={{ maxWidth: 640 }}>
        <div className="row">
          <div className="field" style={{ width: 140 }}>
            <label>الرمز</label>
            <input value={code} onChange={(e) => setCode(e.target.value)} />
          </div>
          <div className="field grow">
            <label>الاسم</label>
            <input value={nameAr} onChange={(e) => setNameAr(e.target.value)} />
          </div>
        </div>

        <div className="field">
          <label>حساب الأصل الثابت (مدين — يحمل التكلفة الأصلية)</label>
          <select value={assetAccountId} onChange={(e) => setAssetAccountId(e.target.value)}>
            <option value="">—</option>
            {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>
        <div className="field">
          <label>حساب مجمع الإهلاك (دائن — يقابله)</label>
          <select value={accumAccountId} onChange={(e) => setAccumAccountId(e.target.value)}>
            <option value="">—</option>
            {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>
        <div className="field">
          <label>حساب مصروف الإهلاك (يُستخدم عند ترحيل الإهلاك لاحقاً)</label>
          <select value={depExpAccountId} onChange={(e) => setDepExpAccountId(e.target.value)}>
            <option value="">—</option>
            {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>
        <div className="field">
          <label>الحساب المقابل (الصندوق/البنك المدفوع منه، أو حساب ذمم)</label>
          <select value={creditAccountId} onChange={(e) => setCreditAccountId(e.target.value)}>
            <option value="">—</option>
            {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>

        <div className="row">
          <div className="field" style={{ width: 160 }}>
            <label>تاريخ الاقتناء</label>
            <input type="date" value={acquisitionDate} onChange={(e) => setAcquisitionDate(e.target.value)} />
          </div>
          <div className="field grow">
            <label>التكلفة</label>
            <input className="num" inputMode="decimal" value={cost} onChange={(e) => setCost(e.target.value)} />
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>قيمة الخردة (اختياري)</label>
            <input className="num" inputMode="decimal" value={salvageValue} onChange={(e) => setSalvageValue(e.target.value)} />
          </div>
          <div className="field grow">
            <label>العمر الإنتاجي (بالأشهر)</label>
            <input className="num" inputMode="numeric" value={usefulLifeMonths} onChange={(e) => setUsefulLifeMonths(e.target.value)} />
          </div>
        </div>
        <div className="field">
          <label>ملاحظات</label>
          <input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </div>

        <p className="muted" style={{ fontSize: '0.85rem' }}>
          التسجيل بيرحّل قيداً مباشرة (مدين حساب الأصل / دائن الحساب المقابل) بكامل التكلفة —
          ما في مسودة قابلة للتعديل بعدين؛ لتصحيح خطأ استبعد الأصل وسجّل نسخة صحيحة بدله.
        </p>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>تسجيل وترحيل</button>
      </div>
    </>
  );
}
