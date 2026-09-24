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

// app.vat_rate(org_id) is now per-organization and editable/toggleable from
// /settings (20250911003500_configurable_tax.sql) — pages read the live
// rate from useOrg().taxRate instead of a static constant. This only
// formats the "(16%)"-style label; the database is the source of truth
// for what actually gets posted.
export const fmtPct = (rate: number) => `${+(rate * 100).toFixed(2)}%`;

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
  [/fiscal year for \S+ is closed, not open/, () => 'السنة المالية لهذا التاريخ مقفلة — لا يمكن الترحيل فيها.'],
  [/fiscal period for \S+ is (\w+), not open/, (m) => `الفترة المحاسبية لهذا التاريخ ${m[1] === 'closed' ? 'مقفلة' : m[1]} — لا يمكن الترحيل فيها.`],
  [/only an open period can be closed/, () => 'هذه الفترة مقفلة بالفعل.'],
  [/cannot close this period while an earlier period is still open — close periods in chronological order/,
    () => 'يجب إقفال الفترات بترتيبها الزمني — أقفل الفترة الأسبق أولاً.'],
  [/a reason is required to reopen a closed period/, () => 'أدخل سبب إعادة فتح الفترة.'],
  [/a reason is required to reopen a closed fiscal year/, () => 'أدخل سبب إعادة فتح السنة المالية.'],
  [/only a closed period can be reopened/, () => 'هذه الفترة مفتوحة أصلاً.'],
  [/the fiscal year is closed — reopen the year before reopening any of its periods/,
    () => 'السنة المالية مقفلة — أعد فتح السنة أولاً قبل أي فترة ضمنها.'],
  [/cannot reopen this period while a later period is still closed — reopen periods in reverse chronological order/,
    () => 'يجب إعادة فتح الفترات بترتيب عكسي — أعد فتح الفترة الأحدث أولاً.'],
  [/only an open fiscal year can be closed/, () => 'هذه السنة المالية مقفلة بالفعل.'],
  [/all \d+ periods must be closed before closing the fiscal year \(\d+ still open\)/,
    () => 'يجب إقفال كل فترات السنة المالية أولاً.'],
  [/only a closed fiscal year can be reopened/, () => 'هذه السنة المالية مفتوحة أصلاً.'],
  [/fiscal (period|year) not found/, () => 'الفترة/السنة المالية غير موجودة.'],
  [/update or delete on table "item_categories" violates foreign key constraint/, () => 'لا يمكن حذف هذه الفئة — يوجد أصناف مرتبطة بها.'],
  [/update or delete on table "account_categories" violates foreign key constraint/, () => 'لا يمكن حذف هذا التصنيف — يوجد حسابات مرتبطة به.'],
  [/duplicate key value violates unique constraint "item_categories_org_id_code_key"/, () => 'هذا الرمز مستخدَم بفئة أخرى.'],
  [/duplicate key value violates unique constraint "account_categories_org_id_code_key"/, () => 'هذا الرمز مستخدَم بتصنيف آخر.'],

  [/no bill of materials for this item and no lines were given explicitly/, () => 'هذا الصنف بلا وصفة تصنيع (BOM) — أضِف مكوّناته أولاً من صفحة الصنف.'],
  [/manufacturing order not found/, () => 'أمر التصنيع غير موجود.'],
  [/manufacturing order has no lines/, () => 'أضف مكوّناً واحداً على الأقل.'],
  [/only a draft manufacturing order can be posted \(this one is (\w+)\)/, () => 'أمر التصنيع مُرحّل أو ملغى بالفعل.'],
  [/a labor cost account is required — this order has a labor cost/, () => 'حدد حساب العمالة — هذا الأمر فيه تكلفة عمالة.'],
  [/an equipment cost account is required — this order has an equipment cost/, () => 'حدد حساب المعدات — هذا الأمر فيه تكلفة معدات.'],
  [/a subcontractor cost account is required — this order has a subcontractor cost/, () => 'حدد حساب المقاولين — هذا الأمر فيه تكلفة مقاولين.'],
  [/an other-cost account is required — this order has an other cost/, () => 'حدد حساب التكاليف الأخرى — هذا الأمر فيه تكلفة أخرى.'],
  [/a posted manufacturing order is immutable; reverse it with void_manufacturing_order\(\)/, () => 'أمر التصنيع المُرحّل ثابت — استخدم الإلغاء لعكسه.'],
  [/only a posted manufacturing order can be voided/, () => 'الإلغاء يكون فقط للأمر المُرحّل.'],
  [/a void manufacturing order cannot be modified/, () => 'هذا الأمر ملغى بالفعل.'],
  [/manufacturing order \S+ is (\w+); its lines are frozen/, () => 'أمر التصنيع لم يعد مسودة — لا يمكن تعديل مكوّناته.'],
  [/violates check constraint "bom_lines_check"/, () => 'لا يمكن أن يكون الصنف مكوّناً لنفسه.'],
  [/duplicate key value violates unique constraint "warehouses_org_id_code_key"/, () => 'هذا الرمز مستخدَم بمستودع آخر.'],

  [/a composite item on this invoice has no recipe \(bom_lines\) defined/, () => 'صنف مركّب بلا وصفة تصنيع (BOM) — أضِف مكوّناته أولاً من صفحة الصنف.'],
  [/a composite item on this invoice has no COGS account set/, () => 'صنف مركّب بلا حساب تكلفة — حدده أولاً من صفحة الصنف.'],
  [/returning a composite item is not supported yet/, () => 'إرجاع صنف مركّب غير مدعوم حالياً.'],
  [/violates check constraint "items_composite_not_stock_tracked"/, () => 'صنف مركّب لا يمكن أن يتتبّع مخزوناً خاصاً به بنفس الوقت.'],
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

  [/system role "[\w-]+" cannot be modified or deleted/, () => 'هذا دور نظامي أساسي — لا يمكن تعديله أو حذفه.'],
  [/system role permissions cannot be modified directly/, () => 'صلاحيات الأدوار النظامية ثابتة ولا يمكن تعديلها.'],
  [/cannot change this member — they are the organization's only remaining active owner/,
    () => 'لا يمكن تعديل هذا العضو — هو المالك الوحيد المُفعَّل حالياً في المؤسسة. عيّن مالكاً آخر أولاً.'],
  [/this person is already a member of this organization/, () => 'هذا الشخص عضو بالفعل في المؤسسة.'],
  [/role does not belong to this organization/, () => 'هذا الدور لا ينتمي لهذه المؤسسة.'],
  [/branch does not belong to this organization/, () => 'هذا الفرع لا ينتمي لهذه المؤسسة.'],
  [/pending invitation not found/, () => 'الدعوة غير موجودة — ربما أُلغيت أو قُبلت بالفعل.'],
  [/membership not found/, () => 'العضوية غير موجودة.'],
  [/email is required/, () => 'أدخل البريد الإلكتروني.'],

  [/this cash drawer already has an open shift/, () => 'هذا الصندوق فيه وردية مفتوحة بالفعل.'],
  [/account \S+ is a group account and cannot be used as a cash drawer/, () => 'هذا حساب تجميع (أب) — اختر حساب صندوق قابل للترحيل.'],
  [/cashier must be an employee dealer in this organization/, () => 'الكاشير لازم يكون طرفاً مسجّلاً بصفة "موظف".'],
  [/cash account not found in this organization/, () => 'حساب الصندوق غير موجود بهذه المؤسسة.'],
  [/shift not found/, () => 'الوردية غير موجودة.'],
  [/only an open shift can be closed \(this one is (\w+)\)/, () => 'هذه الوردية مغلقة بالفعل.'],
  [/a variance account is required — counted cash does not match the expected amount \(variance (-?[\d.]+)\)/,
    (m) => `الجرد ما بيطابق المتوقّع (الفرق ${fmtMoney(Math.abs(Number(m[1])))}) — حدد حساب العجز أو الزيادة لترحيله.`],
  [/variance account belongs to a different organization/, () => 'حساب فرق الجرد لا ينتمي لهذه المؤسسة.'],
  [/cash shift not found, not open, or belongs to a different organization/, () => 'الوردية المختارة غير موجودة أو مغلقة.'],
  [/a closed cash shift cannot be modified/, () => 'هذه الوردية مغلقة — لا يمكن تعديلها.'],

  [/the item's average cost has moved too far since the original purchase.*configure a purchase\/valuation-variance account in Settings first/,
    () => 'تغيّر متوسط تكلفة الصنف كثيرًا منذ الشراء الأصلي بحيث لا يمكن استيعاب هذا المرجع بالكامل داخل المخزون — يلزم تهيئة حساب فروقات تقييم المشتريات من الإعدادات أولًا (الإعدادات ‹ الحسابات الافتراضية).'],
];
export function translateError(message: string): string {
  for (const [re, fn] of ERROR_PATTERNS) {
    const m = message.match(re);
    if (m) return fn(m);
  }
  return message;
}
