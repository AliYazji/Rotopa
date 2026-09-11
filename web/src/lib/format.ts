// '-u-nu-latn' keeps Arabic grouping/decimal conventions but forces Western
// (0-9) digits instead of Arabic-Indic (٠-٩) — the legacy app and every
// report/invoice printout use Western digits, so the rebuild should too.
const AR_LATN = 'ar-EG-u-nu-latn';
const money = new Intl.NumberFormat(AR_LATN, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const int = new Intl.NumberFormat(AR_LATN);

export const fmtMoney = (n: number | null | undefined) => money.format(Number(n ?? 0));
export const fmtInt = (n: number | null | undefined) => int.format(Number(n ?? 0));
export const fmtDate = (d: string | null | undefined) =>
  d ? new Date(d).toLocaleDateString(AR_LATN, { year: 'numeric', month: '2-digit', day: '2-digit' }) : '';

export const today = () => new Date().toISOString().slice(0, 10);

// Mirrors app.vat_rate() on the database side (20250911002000_vat.sql) —
// single flat rate for the whole system, no per-item exemption yet. Only
// used here to show the customer/supplier-facing total before posting;
// the database is the actual source of truth for what gets posted.
export const VAT_RATE = 0.16;

/**
 * PostgREST's .or()/.ilike() filter strings are built by hand-interpolating
 * the search term — `,` separates conditions and `.`/`(`/`)` are part of its
 * own grammar, so a search box that lets someone type those breaks the query
 * (or, worse, changes what it filters on) rather than just finding nothing.
 * Strip them before building any such filter string.
 */
export const sanitizeSearchTerm = (q: string) => q.trim().replace(/[,()."]/g, '');

/**
 * Every write form shows `err.message` straight from Postgres. That's the
 * right level of detail in the SQL tests, but a viewer of the app shouldn't
 * see "insufficient stock: item 10002 at warehouse has 0.0000 on hand, need
 * 2.0000" as raw English — they should see what to do about it, in Arabic.
 * Falls through to the raw message for anything not recognised, so nothing
 * is ever silently swallowed.
 */
const ERROR_PATTERNS: [RegExp, (m: RegExpMatchArray) => string][] = [
  [/insufficient stock: item (\S+) at warehouse has ([\d.]+) on hand, need ([\d.]+)/,
    (m) => `الكمية غير متوفرة: رصيد الصنف ${m[1]} الحالي ${fmtMoney(Number(m[2]))} والمطلوب ${fmtMoney(Number(m[3]))}. تحقق من المستودع أو رحّل رصيداً إضافياً أولاً.`],
  [/no fiscal period defined for (\S+)/, (m) => `لا توجد فترة محاسبية معرَّفة لتاريخ ${m[1]}.`],
  [/fiscal period for \S+ is (\w+), not open/, (m) => `الفترة المحاسبية لهذا التاريخ ${m[1] === 'closed' ? 'مقفلة' : m[1]} — لا يمكن الترحيل فيها.`],
  [/not authorized: (\S+) on org/, () => 'لا تملك الصلاحية اللازمة لهذا الإجراء.'],
  [/account \S+ is not postable/, () => 'هذا الحساب حساب تجميع (أب) ولا يقبل حركات مباشرة.'],
  [/does not currently accept transactions/, () => 'هذا الحساب موقوف مؤقتاً عن قبول الحركات.'],
  [/a posted (entry|voucher|invoice|move|payroll run) is immutable/, () => 'لا يمكن تعديل مستند مُرحّل — استخدم الإلغاء لعكسه.'],
  [/only a draft ([\w ]+?) can be posted/, () => 'المستند مُرحّل أو ملغى بالفعل.'],
  [/only a posted [\w ]+ can be voided/, () => 'الإلغاء يكون فقط للمستند المرحّل — هذا مسودة أو ملغى بالفعل.'],
  [/^[\w ]+ has no lines$/, () => 'أضف سطراً واحداً على الأقل قبل الترحيل.'],
  [/^[\w ]+ not found$/, () => 'المستند غير موجود — ربما حُذف أو أُعيد تحميل الصفحة بمعرّف قديم.'],

  // "required account" family — each posting path lists exactly which
  // account it needed and why, so translate each concrete message rather
  // than a single generic catch-all.
  [/a tax payable account is required/, () => 'حدد حساب ضريبة الدخل المستحقة — هذا الكشف فيه استقطاعات ضريبة.'],
  [/a loan receivable account is required/, () => 'حدد حساب سلف الموظفين — هذا الكشف فيه استقطاعات سلف.'],
  [/an other-deductions account is required/, () => 'حدد حساب الاستقطاعات الأخرى — هذا الكشف فيه استقطاعات متنوعة.'],
  [/an employee on this run has no salary expense account and no default was given/,
    () => 'أحد الموظفين بلا حساب مصروف رواتب خاص، وما حُدّد حساب افتراضي. حدد حساباً افتراضياً للكشف أو حساباً خاصاً لهذا الموظف.'],
  [/an item on this invoice has no sales account and no default was given/,
    () => 'أحد الأصناف بلا حساب مبيعات خاص، وما حُدّد حساب افتراضي. حدد حساباً افتراضياً للفاتورة أو حساباً خاصاً لهذا الصنف.'],
  [/a proceeds account is required when proceeds > 0/, () => 'حدد حساب استلام العائد — أدخلت مبلغاً أكبر من صفر.'],
  [/a gain\/loss account is required — proceeds \(([\d.]+)\) differ from net book value \(([\d.]+)\)/,
    (m) => `حدد حساب أرباح/خسائر الاستبعاد — العائد (${fmtMoney(Number(m[1]))}) يختلف عن صافي القيمة الدفترية (${fmtMoney(Number(m[2]))}).`],
  [/a bank account is required to clear a cheque/, () => 'حدد حساب البنك لتحصيل الشيك.'],

  [/dealer \S+ is not marked as an employee/, () => 'هذا الطرف غير مسجّل كموظف — أضف صفة "موظف" له أولاً.'],
  [/dealer is not marked as a customer/, () => 'هذا الطرف غير مسجّل كعميل.'],
  [/dealer is not marked as a supplier/, () => 'هذا الطرف غير مسجّل كمورّد.'],
];
export function translateError(message: string): string {
  for (const [re, fn] of ERROR_PATTERNS) {
    const m = message.match(re);
    if (m) return fn(m);
  }
  return message;
}
