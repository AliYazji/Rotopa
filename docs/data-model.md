# نموذج البيانات — المرحلة 1

هذا المستند يشرح المخطط ويربطه بجداول النظام القديم (`miles2023`).

## المبادئ

1. **مؤسسة واحدة لكل صف.** كل جدول نطاقي فيه `org_id`. لا استعلام يتجاوز حدود المؤسسة (RLS).
2. **عملة الأساس هي الحقيقة.** `journal_lines.debit/credit` دائماً بعملة أساس المؤسسة. المبالغ الأجنبية (`fc_debit/fc_credit`) تُخزَّن بجانبها مع `rate`.
3. **الأرقام دقيقة.** `numeric(19,4)` للمبالغ، `numeric(19,9)` للأسعار. لا `float/real` (كانت مصدر اختلال 0.06 في النظام القديم).
4. **المنطق في طبقة واحدة.** الإنشاء والترحيل والإلغاء عبر دوال `create_journal_entry` / `post_journal_entry` / `void_journal_entry` فقط.
5. **المفاتيح الخارجية حقيقية.** `on delete restrict` افتراضياً — لا يُحذف شيء مشار إليه.

## الوحدة 00 — المنصة

| جدول | الغرض | يقابل |
|---|---|---|
| `organizations` | المؤسسة (المستأجر). `base_currency_id`, `fiscal_year_start_month` | — |
| `branches` | الفروع | `center_tb` جزئياً |
| `profiles` | ملف لكل مستخدم Auth (يُنشأ تلقائياً عند التسجيل) | `login_tb` |
| `permissions` | فهرس الصلاحيات العام (`module.action`) | `PERMISON_TB` |
| `roles` / `role_permissions` | أدوار لكل مؤسسة | `group_tb` / `GroupPermsion` |
| `memberships` | ربط مستخدم ↔ مؤسسة + دور + `is_owner` | — |
| `lookups` | قيمة واحدة لكل صف مُعدّد (`category`,`code`,`name_ar`) | `Lockup_tb` (181 عمود → صفوف) |
| `org_settings` | مفتاح/قيمة JSON | `Logo_tb` (181 عمود) |
| `audit_log` | سجل إلحاقي لكل تغيير | `history`, `UsersActivities_tb` |

### الصلاحيات (RBAC)

- `app.is_member(org)` — عضو نشط؟
- `app.has_permission(org, key)` — عضو + (مالك أو الدور يملك المفتاح)
- `app.require_permission(org, key)` — نفس السابق لكن يرمي `42501` (تُستخدم داخل الدوال)

الأدوار المبذورة عند `create_organization`: `owner` (كل شيء)، `accountant` (كل شيء عدا إدارة المؤسسة/الأدوار/الأعضاء)، `viewer` (قراءة فقط).

## الوحدة 02 — العملات والتقويم المالي

| جدول | الغرض | يقابل |
|---|---|---|
| `currencies` | العملات، واحدة `is_base` لكل مؤسسة | `Lockup 'Currancy'` |
| `exchange_rates` | سعر يوم واحد لكل عملة (`rate`, `buy_rate`, `sell_rate`) | `currancy_rate_tb` (30 عمود عريض → صفوف) |
| `fiscal_years` | السنة المالية، `status` open/closed | — |
| `fiscal_periods` | 12 فترة شهرية، `status` open/closed/locked، لا تتداخل | — |

الدوال:
- `fx_rate(currency_id, date)` → سعر الصرف الساري في التاريخ (أحدث سعر ≤ التاريخ؛ 1 للأساس؛ لا يرجع NULL أبداً)
- `to_base(amount, rate)` → `round(amount*rate, 4)`
- `app.open_period_for(org, date)` → معرّف الفترة، أو خطأ إن لم توجد/غير مفتوحة

## الوحدة 01 — دليل الحسابات

| جدول | الغرض | يقابل |
|---|---|---|
| `account_categories` | بند القائمة المالية: `statement` (ميزانية/دخل)، `section` (أصل/خصم/حقوق/إيراد/مصروف)، `normal_balance`، `cashflow_section` | `accountCategoryType_tb` + `AccountType` |
| `accounts` | الشجرة | `master_acc` |

حقول `accounts` المهمة:

| حقل | معنى | مصدر قديم |
|---|---|---|
| `code` | رقم الحساب (نص، فريد بالمؤسسة) | `acc_no` (كلها 5 خانات) |
| `parent_id` | الأب في الشجرة | `father_acc` |
| `nature` | `debit` / `credit` / `both` | `account_nature` (1=دائن→credit، 2=مدين→debit، 3=both — لاحظ أن التسميات الإنجليزية بالنظام القديم مقلوبة) |
| `is_postable` | ورقة تقبل حركات؟ الأب لا | `acc_lavel` (1/3 ورقة، 2 أب) |
| `allow_transactions` | إيقاف مؤقت | `StopTransaction` |
| `currency_id` | تقييد بعملة واحدة (NULL = أي) | `currncey` |
| `is_control` + `control_type` | حساب مراقبة يلخّص دفتراً مساعداً | ضمني (11201 «اجمالي ذمم الزبائن»…) |
| `require_dealer` / `require_cost_center` / … | أبعاد إلزامية عند الترحيل | — (تحسين) |
| `path` (ltree) / `depth` | تُصان بمُشغّل — استعلام شجري سريع | — |

قواعد الشجرة (مُشغّلات):
- إضافة ابن تحت حساب `is_postable` → خطأ (اجعله أباً أولاً)
- جعل حساب `is_postable` وله أبناء → خطأ
- نقل حساب تحت نفسه/سليله → خطأ (منع الدورات)
- تغيير أب أو `code` → يُعاد بناء `path`/`depth` لكل السلالة

## الوحدة 03 — الأبعاد

`cost_centers`, `departments`, `funds`, `projects` — أشجار مسطّحة بسيطة، كلها بصلاحية `dimensions.write`.
`budgets` + `budget_lines` — مبلغ مخطط لكل حساب/فترة (`budget_dt` القديم بأعمدة `month1..12` → صفوف بـ `period_no`).

## الوحدة 04 — العملاء والموردون والموظفون

`dealers` — صف واحد لكل جهة، الأدوار أعلام (`is_customer/is_supplier/is_employee`) بدل صف لكل نوع كما في `Dealers_tb` (مفتاحه `Dealer_no + Dealer_type`).
لكل تاجر `account_id` → حساب ورقة في الدليل. مُشغّل يتحقق أنه بنفس المؤسسة وورقة.

## الوحدة 05 — محرك القيود

### `journal_entries`
رأس القيد. `entry_no` تسلسل لكل مؤسسة (`app.next_seq`). `status`: `draft` → `posted` → `void`.
`source_type` + `source_id` = المستند المصدر (فريد: قيد واحد لكل مستند). `void_of` / `reversed_by` تربط القيد بعكسه.

### `journal_lines`
`debit`/`credit` بعملة الأساس. `currency_id`+`rate`+`fc_debit`/`fc_credit` = المستند الأصلي.
أبعاد: `dealer_id`, `cost_center_id`, `department_id`, `fund_id`, `project_id`, `budget_id`.

### القيود المفروضة
| القاعدة | آلية |
|---|---|
| سطر = مدين XOR دائن، > 0 | `check` |
| مبلغ الأساس = الأجنبي × السعر | مُشغّل `tg_journal_line_validate` |
| الحساب ورقة/نشط/يقبل حركات، عملته متوافقة، أبعاده الإلزامية موجودة | مُشغّل |
| القيد المرحّل ≥ سطرين ومتوازن | مُشغّل قيد `journal_entry_balanced` (عند بلوغ `posted`) |
| لا تعديل على سطور قيد غير مسودة | مُشغّلات `tg_journal_line_validate` / `tg_journal_line_frozen` |
| القيد المرحّل ثابت (إلا → void) | مُشغّل `tg_journal_entry_guard` |
| لا ترحيل في فترة مقفلة | `app.open_period_for` عند الإنشاء + إعادة فحص عند `post` |

### `account_period_balances`
تجميع (`account_id`, `fiscal_period_id`) → `debit_base`, `credit_base`. يُحدَّث بمُشغّل عند بلوغ القيد `posted`.
الإلغاء **لا** يطرح من التجميع — القيد العكسي هو ما يوازن (لا نعيد كتابة فترة مقفلة).
`account_balance(account_id, as_of)` يقرأ منه — ميزان مراجعة O(1).

### الدوال (RPC — الطريق الوحيد المدعوم)
```
create_journal_entry(org, entry_date, description, lines jsonb,
                     source_type='manual', source_id=null, branch_id=null,
                     document_currency_id=null, is_opening=false) → uuid   -- مسودة
post_journal_entry(entry_id) → void
void_journal_entry(entry_id, date, reason) → uuid   -- ينشئ قيداً عكسياً ويرحّله
```
