import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { today, translateError } from '../lib/format.ts';

interface AccOpt { id: string; code: string; name_ar: string; }
interface DealerOpt { id: string; code: string; name_ar: string; is_customer: boolean; is_supplier: boolean; }

export default function ChequeNew() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const direction = params.get('direction') === 'outgoing' ? 'outgoing' : 'incoming';

  const [chequeNo, setChequeNo] = useState('');
  const [date, setDate] = useState(today());
  const [bankName, setBankName] = useState('');
  const [partyName, setPartyName] = useState('');
  const [amount, setAmount] = useState('');
  const [dealerId, setDealerId] = useState('');
  const [holdingAccountId, setHoldingAccountId] = useState('');
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar')
        .eq('is_postable', true).eq('allow_transactions', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  const { data: dealers } = useQuery({
    queryKey: ['dealers-lite', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<DealerOpt[]> => {
      const { data, error } = await supabase.from('dealers').select('id, code, name_ar, is_customer, is_supplier').order('name_ar');
      if (error) throw error;
      return data as DealerOpt[];
    },
  });
  const relevantDealers = dealers?.filter((d) => (direction === 'incoming' ? d.is_customer : d.is_supplier));

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      if (!dealerId || !holdingAccountId || !chequeNo || !(parseFloat(amount) > 0)) {
        throw new Error('أكمل الحقول المطلوبة: رقم الشيك، المبلغ، الطرف، حساب الشيكات');
      }
      const { error } = await supabase.rpc('create_cheque', {
        p_org: org!.id,
        p_direction: direction,
        p_cheque_no: chequeNo,
        p_cheque_date: date,
        p_amount: parseFloat(amount),
        p_currency_id: org!.base_currency_id,
        p_dealer_id: dealerId,
        p_holding_account_id: holdingAccountId,
        p_bank_name: bankName || null,
        p_party_name: partyName || null,
        p_notes: notes || null,
      });
      if (error) throw error;
      nav('/cheques');
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>{direction === 'incoming' ? 'تسجيل شيك وارد' : 'تسجيل شيك صادر'}</h1>
      <p className="muted" style={{ maxWidth: '60ch' }}>
        هذا يسجّل بيانات الشيك فقط. تأكد إنك رحّلت سند {direction === 'incoming' ? 'قبض' : 'صرف'} بنفس
        المبلغ إلى حساب الشيكات المختار — تسجيل الشيك هون ما بيرحّل قيداً تلقائياً؛ فقط تحصيله أو ارتداده
        أو إلغاؤه لاحقاً هو يلي بيرحّل.
      </p>
      <div className="card">
        <div className="row">
          <div className="field grow">
            <label>رقم الشيك</label>
            <input value={chequeNo} onChange={(e) => setChequeNo(e.target.value)} dir="ltr" />
          </div>
          <div className="field" style={{ width: 180 }}>
            <label>تاريخ الاستحقاق</label>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
        </div>
        <div className="row">
          <div className="field grow">
            <label>{direction === 'incoming' ? 'العميل' : 'المورد'}</label>
            <select value={dealerId} onChange={(e) => setDealerId(e.target.value)}>
              <option value="">—</option>
              {relevantDealers?.map((d) => <option key={d.id} value={d.id}>{d.name_ar}</option>)}
            </select>
          </div>
          <div className="field" style={{ width: 150 }}>
            <label>المبلغ</label>
            <input className="num" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
        </div>
        <div className="field">
          <label>حساب الشيكات ({direction === 'incoming' ? 'تحت التحصيل' : 'تحت الدفع'})</label>
          <select value={holdingAccountId} onChange={(e) => setHoldingAccountId(e.target.value)}>
            <option value="">—</option>
            {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
          </select>
        </div>
        <div className="row">
          <div className="field grow">
            <label>اسم البنك (اختياري)</label>
            <input value={bankName} onChange={(e) => setBankName(e.target.value)} />
          </div>
          <div className="field grow">
            <label>{direction === 'incoming' ? 'الساحب' : 'المستفيد'} (اختياري)</label>
            <input value={partyName} onChange={(e) => setPartyName(e.target.value)} />
          </div>
        </div>
        <div className="field">
          <label>ملاحظات</label>
          <input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </div>

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save}>حفظ</button>
      </div>
    </>
  );
}
