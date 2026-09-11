import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';

interface AccOpt { id: string; code: string; name_ar: string; }

export default function DealerNew() {
  const { org } = useOrg();
  const nav = useNavigate();

  const [name, setName] = useState('');
  const [isCustomer, setIsCustomer] = useState(true);
  const [isSupplier, setIsSupplier] = useState(false);
  const [isEmployee, setIsEmployee] = useState(false);
  const [parentAccountId, setParentAccountId] = useState('');
  const [creditLimit, setCreditLimit] = useState('');
  const [phone, setPhone] = useState('');
  const [email, setEmail] = useState('');
  const [address, setAddress] = useState('');
  const [city, setCity] = useState('');
  const [taxNo, setTaxNo] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // header (non-postable) accounts — the dealer's own account is created under one of these
  const { data: headers } = useQuery({
    queryKey: ['header-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar')
        .eq('is_postable', false).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (!name.trim()) throw new Error('اكتب اسم الطرف');
      if (!parentAccountId) throw new Error('اختر الحساب الأب (مثل «العملاء» أو «الموردون»)');
      if (!isCustomer && !isSupplier && !isEmployee) throw new Error('اختر دوراً واحداً على الأقل');

      const { error } = await supabase.rpc('create_dealer', {
        p_org: org!.id,
        p_name_ar: name,
        p_parent_account_id: parentAccountId,
        p_is_customer: isCustomer,
        p_is_supplier: isSupplier,
        p_is_employee: isEmployee,
        p_credit_limit: parseFloat(creditLimit) || 0,
        p_phone: phone || null,
        p_email: email || null,
        p_address: address || null,
        p_city: city || null,
        p_tax_no: taxNo || null,
      });
      if (error) throw error;
      nav('/dealers');
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>طرف جديد</h1>
      <div className="card" style={{ maxWidth: 560 }}>
        <div className="field">
          <label>الاسم</label>
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="اسم العميل / المورد / الموظف" />
        </div>

        <div className="field">
          <label>الأدوار</label>
          <div className="row" style={{ gap: '1.25rem' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="checkbox" style={{ width: 'auto' }} checked={isCustomer} onChange={(e) => setIsCustomer(e.target.checked)} /> عميل
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="checkbox" style={{ width: 'auto' }} checked={isSupplier} onChange={(e) => setIsSupplier(e.target.checked)} /> مورد
            </label>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', width: 'auto', margin: 0 }}>
              <input type="checkbox" style={{ width: 'auto' }} checked={isEmployee} onChange={(e) => setIsEmployee(e.target.checked)} /> موظف
            </label>
          </div>
        </div>

        <div className="field">
          <label>الحساب الأب (بيُنشأ للطرف حساب فرعي تحته تلقائياً)</label>
          <select value={parentAccountId} onChange={(e) => setParentAccountId(e.target.value)}>
            <option value="">—</option>
            {headers?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>

        <div className="row">
          <div className="field grow">
            <label>الهاتف</label>
            <input value={phone} onChange={(e) => setPhone(e.target.value)} dir="ltr" />
          </div>
          <div className="field grow">
            <label>المدينة</label>
            <input value={city} onChange={(e) => setCity(e.target.value)} />
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>البريد الإلكتروني</label>
            <input value={email} onChange={(e) => setEmail(e.target.value)} dir="ltr" />
          </div>
          <div className="field" style={{ width: 160 }}>
            <label>حد الائتمان</label>
            <input className="num" inputMode="decimal" value={creditLimit} onChange={(e) => setCreditLimit(e.target.value)} />
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>العنوان</label>
            <input value={address} onChange={(e) => setAddress(e.target.value)} />
          </div>
          <div className="field grow">
            <label>الرقم الضريبي</label>
            <input value={taxNo} onChange={(e) => setTaxNo(e.target.value)} dir="ltr" />
          </div>
        </div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>حفظ</button>
      </div>
    </>
  );
}
