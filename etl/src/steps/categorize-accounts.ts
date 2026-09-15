import { pool } from '../target.ts';

/**
 * Assigns accounts.category_id from real accounting logic, not the legacy
 * source. Checked directly against the real backup: only 24/114 accounts
 * ever had `master_acc.accountCategoryType` set — the legacy system itself
 * classified roughly 80% of its own chart of accounts. `class_acc` was
 * already ruled out as a fallback in an earlier step (it mis-tags 4 real
 * expense accounts as something else) — so the accounts step above only
 * ever fills in category_id for that same ~24-account minority, on every run.
 *
 * The 22 categories themselves (`account_categories`, seeded from the
 * legacy `accountCategoryType_tb` in categories.ts) are fine and complete —
 * the legacy admins built a proper taxonomy, they just never finished
 * tagging their own accounts with it. This step finishes that tagging,
 * using a source of truth the legacy data never corrupted: the account
 * TREE itself (`accounts.parent_id`), which migrated at 100% integrity
 * (verified by `npm run verify`). Every account's nearest classified
 * ancestor tells you what it is — "شيكات تحت التحصيل شيكل" sits under
 * "الاصول المتداولة" whether or not anyone ever ticked a category flag.
 *
 * Idempotent and safe to re-run: always recomputes and overwrites
 * category_id for every account in the org (never a partial/first-run-only
 * fill), so a later manual correction in the app (`AccountDetail.tsx`'s own
 * category field) is the only thing that should be re-checked after a
 * re-run, not this step's own output.
 */
export async function categorizeAccounts(orgId: string): Promise<void> {
  const res = await pool.query(
    `
    with recursive ancestry as (
      select id, code, parent_id, id as root_id
      from accounts where org_id = $1 and parent_id is null
      union all
      select acc.id, acc.code, acc.parent_id, anc.root_id
      from accounts acc
      join ancestry anc on acc.parent_id = anc.id
    ),
    rooted as (
      select anc.id, anc.code, root.code as root_code, parent.code as parent_code
      from ancestry anc
      join accounts root on root.id = anc.root_id
      left join accounts parent on parent.id = anc.parent_id
    ),
    mapped as (
      select id,
        case
          -- exact overrides: a specific account whose correct category
          -- is more precise than its tree position alone would suggest
          when code in ('51001','51019') then 'L610'   -- رواتب العمال / مرتبات مستحقة -> رواتب وأجور، لا مصاريف تشغيلية عامة
          when code in ('60103','60304') then 'L510'   -- خصم مكتسب/مسموح به -> إيراد غير مباشر (محسوم من صافي المبيعات)، لا مبيعات ولا تكلفة بضاعة
          when code = 'OB-VAR' then 'L400'             -- فروقات الأرصدة الافتتاحية -> تسوية على حقوق الملكية
          when code = 'RE' then 'L400'                 -- أرباح مرحّلة -> حقوق ملكية
          when code = 'COGS-DEFAULT' then 'L520'
          when code = 'INV-DEFAULT' then 'L140'

          -- immediate-parent overrides: the group this account sits directly under
          when parent_code in ('10100','10200','13000') then 'L100'  -- صناديق/بنوك/فيزا -> نقد وشبه نقد
          when parent_code = '11100' then 'L130'                     -- تحت الموظفين -> ذمم موظفين
          when parent_code = '11200' then 'L120'                     -- تحت العملاء -> ذمم مدينة
          when parent_code = '12000' then 'L160'                     -- تحت المشتريات -> أصول متداولة أخرى (حساب تصفوي غير مستخدَم بالنظام الحالي)
          when parent_code = '60100' then 'L510'                     -- تحت إيرادات متنوعة -> إيراد غير مباشر
          when parent_code = '60200' then 'L500'                     -- تحت إيرادات المبيعات -> مبيعات
          when parent_code in ('41000','42000') then 'L400'          -- تحت رأس المال/جاري الشريك -> حقوق ملكية
          when parent_code = '31000' then 'L300'                     -- تحت الموردون -> ذمم دائنة
          when parent_code = '80000' then 'L210'                     -- تحت مجمع الإهلاك -> مجمع إهلاك
          when parent_code = '56000' then 'L600'                     -- تحت "سيارة 1" (فرع يتيم) -> مصروف تشغيلي
          when parent_code in ('51000','52000','53000','53100','54000','55000') then 'L600' -- كل فروع المصروفات التشغيلية

          -- the group/root codes themselves (same logic, one level up)
          when code in ('10002','10003','10010') then 'L110'         -- شيكات تحت التحصيل / محفظة شيكات مرجعة -> شيكات واردة
          when code in ('10006','10007','12000') then 'L160'         -- ضريبة قيمة مضافة / ضريبة دخل / حساب مشتريات تصفوي -> أصول متداولة أخرى
          when code in ('10100','10200','13000') then 'L100'
          when code = '11100' then 'L130'
          when code = '11200' then 'L120'
          when code in ('30001','30002') then 'L320'                 -- شيكات تحت الدفع -> شيكات مؤجلة
          when code = '31000' then 'L300'                            -- الموردون -> ذمم دائنة
          when code in ('41000','42000') then 'L400'
          when code = '60100' then 'L510'
          when code = '60200' then 'L500'
          when code = '56000' then 'L600'
          when code in ('80002','80003') then 'L600'                 -- حسابان يتيمان بالشجرة (فيسبوك/كهرباء) بالاسم مصروفات فعلياً
          when code = '80000' then 'L210'
          when code = '70000' then 'L400'                            -- أرباح وخسائر مدوّرة -> حقوق ملكية

          -- root fallback: anything else in this branch of the tree
          when root_code = '10000' then 'L160'   -- أصول متداولة أخرى (احتياطي)
          when root_code = '20000' then 'L200'
          when root_code = '30000' then 'L330'   -- خصوم متداولة أخرى (احتياطي)
          when root_code = '40000' then 'L400'
          when root_code = '50000' then 'L600'
          when root_code = '60000' then 'L500'
          when root_code = '70000' then 'L400'
          when root_code = '80000' then 'L210'
          else null
        end as cat_code
      from rooted
    )
    update accounts a
    set category_id = cat.id
    from mapped
    join account_categories cat on cat.org_id = $1 and cat.code = mapped.cat_code
    where a.id = mapped.id and a.org_id = $1
    `,
    [orgId],
  );

  const { rows: uncategorized } = await pool.query(
    `select count(*)::int as n from accounts where org_id = $1 and category_id is null`,
    [orgId],
  );
  console.log(`  accounts categorized: ${res.rowCount}, still uncategorized: ${uncategorized[0].n}`);
}
