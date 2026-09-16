import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney } from '../lib/format.ts';

interface PrintSettings { address?: string; phone?: string; footer_note?: string; }
interface PrintLine {
  key: string; label: string; qty: number; unitLabel: string; unitPrice: number; discountPct: number; total: number;
}

export function PrintInvoice({
  docTitle, docNo, docDate, dueDate, partyLabel, partyName, cashierName, lines, subtotal, vat, total,
}: {
  docTitle: string; docNo: number; docDate: string; dueDate?: string | null;
  partyLabel: string; partyName: string; cashierName?: string | null; lines: PrintLine[];
  subtotal: number; vat: number; total: number;
}) {
  const { org } = useOrg();
  const { data: print } = useQuery({
    queryKey: ['org-print-settings', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<PrintSettings | null> => {
      const { data, error } = await supabase.from('org_settings').select('value').eq('org_id', org!.id).eq('key', 'print').maybeSingle();
      if (error) throw error;
      return (data?.value as PrintSettings) ?? null;
    },
  });

  return (
    <div className="print-only">
      <div className="print-header">
        <div>
          <h1>{org?.name_ar}</h1>
          {print?.address && <div>{print.address}</div>}
          {print?.phone && <div dir="ltr" style={{ textAlign: 'right' }}>{print.phone}</div>}
        </div>
        <div style={{ textAlign: 'left' }}>
          <h2 style={{ margin: 0 }}>{docTitle}</h2>
          <div>رقم: {docNo}</div>
          <div>التاريخ: {fmtDate(docDate)}</div>
          {dueDate && <div>الاستحقاق: {fmtDate(dueDate)}</div>}
        </div>
      </div>

      <div><strong>{partyLabel}:</strong> {partyName}</div>
      {cashierName && <div><strong>الكاشير:</strong> {cashierName}</div>}

      <table className="print-table">
        <thead>
          <tr>
            <th>الصنف</th>
            <th>الكمية</th>
            <th>السعر</th>
            <th>خصم %</th>
            <th>الإجمالي</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => (
            <tr key={l.key}>
              <td>{l.label}</td>
              <td>{fmtMoney(l.qty)} {l.unitLabel}</td>
              <td>{fmtMoney(l.unitPrice)}</td>
              <td>{l.discountPct}</td>
              <td>{fmtMoney(l.total)}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          {vat > 0 && <tr><td colSpan={4}>المجموع قبل الضريبة</td><td>{fmtMoney(subtotal)}</td></tr>}
          {vat > 0 && <tr><td colSpan={4}>ضريبة القيمة المضافة</td><td>{fmtMoney(vat)}</td></tr>}
          <tr style={{ fontWeight: 700 }}><td colSpan={4}>الإجمالي</td><td>{fmtMoney(total)}</td></tr>
        </tfoot>
      </table>

      {print?.footer_note && <div className="print-footer-note">{print.footer_note}</div>}
    </div>
  );
}
