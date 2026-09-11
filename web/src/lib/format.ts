const money = new Intl.NumberFormat('ar-EG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const int = new Intl.NumberFormat('ar-EG');

export const fmtMoney = (n: number | null | undefined) => money.format(Number(n ?? 0));
export const fmtInt = (n: number | null | undefined) => int.format(Number(n ?? 0));
export const fmtDate = (d: string | null | undefined) =>
  d ? new Date(d).toLocaleDateString('ar-EG', { year: 'numeric', month: '2-digit', day: '2-digit' }) : '';

export const today = () => new Date().toISOString().slice(0, 10);

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
  [/account % ?is not postable/, () => 'هذا الحساب حساب تجميع (أب) ولا يقبل حركات مباشرة.'],
  [/does not currently accept transactions/, () => 'هذا الحساب موقوف مؤقتاً عن قبول الحركات.'],
  [/a posted (entry|voucher|invoice|move) is immutable/, () => 'لا يمكن تعديل مستند مُرحّل — استخدم الإلغاء لعكسه.'],
  [/only a draft (\w+) can be posted/, () => 'المستند مُرحّل أو ملغى بالفعل.'],
];
export function translateError(message: string): string {
  for (const [re, fn] of ERROR_PATTERNS) {
    const m = message.match(re);
    if (m) return fn(m);
  }
  return message;
}
