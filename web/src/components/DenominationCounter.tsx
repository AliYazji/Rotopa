import { fmtMoney } from '../lib/format.ts';

// shekel notes/coins in circulation — the same fixed set the legacy system
// used (CashControlTb: Cash01/02/05/10/20/50/100/200); "أخرى" covers any
// other currency's denominations without hardcoding a second list
const DEFAULT_DENOMINATIONS = [200, 100, 50, 20, 10, 5, 2, 1];

export type Denominations = Record<string, string>;

export function denominationsTotal(d: Denominations): number {
  return Object.entries(d).reduce((s, [k, v]) => s + (Number(k) || 0) * (Number(v) || 0), 0);
}

/** counts bills/coins by denomination and totals them live — used for both
 * opening and closing a cash-drawer shift */
export function DenominationCounter({ value, onChange }: { value: Denominations; onChange: (v: Denominations) => void }) {
  const extraKeys = Object.keys(value).filter((k) => !DEFAULT_DENOMINATIONS.includes(Number(k)));

  function setCount(denom: string, count: string) {
    onChange({ ...value, [denom]: count });
  }
  function addCustomDenomination() {
    const d = prompt('فئة جديدة (مثلاً 25 أو قيمة عملة أخرى)');
    if (!d || !d.trim() || isNaN(Number(d))) return;
    onChange({ ...value, [d.trim()]: value[d.trim()] ?? '0' });
  }

  return (
    <div>
      <table style={{ maxWidth: 360 }}>
        <thead><tr><th>الفئة</th><th className="num">العدد</th><th className="num">المجموع</th></tr></thead>
        <tbody>
          {[...DEFAULT_DENOMINATIONS.map(String), ...extraKeys].map((denom) => (
            <tr key={denom}>
              <td className="mono">{denom}</td>
              <td>
                <input className="num" inputMode="numeric" style={{ width: 70 }}
                  value={value[denom] ?? ''} onChange={(e) => setCount(denom, e.target.value)} />
              </td>
              <td className="num mono">{fmtMoney((Number(denom) || 0) * (Number(value[denom]) || 0))}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr style={{ fontWeight: 700 }}>
            <td colSpan={2}>الإجمالي</td>
            <td className="num mono">{fmtMoney(denominationsTotal(value))}</td>
          </tr>
        </tfoot>
      </table>
      <button type="button" onClick={addCustomDenomination} style={{ marginTop: '0.4rem', fontSize: '0.8rem' }}>+ فئة أخرى</button>
    </div>
  );
}
