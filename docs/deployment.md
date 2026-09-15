# النشر

## 1. قاعدة البيانات — Supabase Cloud

```bash
npx supabase login
npx supabase link --project-ref <your-ref>
npx supabase db push          # يطبّق supabase/migrations/ بالترتيب
```

بعد أول دفع:
- في Supabase Studio → Authentication → أنشئ مستخدمك.
- شغّل ETL لتحميل بيانات `miles2023` (انظر `etl/README.md`)، مع
  `ADMIN_USER_ID` = معرّف مستخدمك، أو أنشئ المؤسسة من التطبيق (`create_organization`).

### إعادة التحقق

```bash
PGURL="postgres://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" \
  bash supabase/tests/run.sh     # يطبّق على قاعدة نظيفة — لا تشغّله على قاعدة الإنتاج
```

## 2. الويب — Cloudflare Pages

**الإعدادات في لوحة Pages:**

| الحقل | القيمة |
|---|---|
| Framework preset | None / Vite |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Root directory | `web` |
| Node version | 20 |

**متغيرات البيئة (Production + Preview):**

```
VITE_SUPABASE_URL       = https://<ref>.supabase.co
VITE_SUPABASE_ANON_KEY  = <anon key>
```

`web/public/_redirects` يوجّه كل المسارات إلى `index.html` (تطبيق صفحة واحدة).

**في Supabase → Authentication → URL Configuration:** أضف نطاق Pages إلى
Site URL و Redirect URLs.

## بيئة التطوير المحلي (اختياري)

الاختبارات تعزل نفسها في حاوية `rotopa-pgtest` عبر Docker — لا تحتاج
`supabase start`. لتشغيل الحزمة الكاملة محلياً استخدم `project_id` مختلفاً
في `supabase/config.toml` (حاوية `supabase_db_rotopa` الحالية تخص مشروعاً آخر).

## 3. النسخ الاحتياطي والاستعادة

```bash
scripts/backup-db.sh                       # الحاوية المحلية، قاعدة "postgres" — الافتراضي
PGCONTAINER=<container> scripts/backup-db.sh
PGURL="postgres://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" scripts/backup-db.sh   # Supabase Cloud
```

- الملف الناتج `backups/rotopa_backup_<تاريخ_ووقت>.dump` (مُتجاهَل من git). الاحتفاظ التلقائي
  بآخر 10 نسخ فقط (`KEEP=<عدد>` للتحكم).
- النسخة تشمل فقط المخططات التي يملكها هذا التطبيق فعلياً: `public` (كل الجداول)، `app` (دوال
  الصلاحيات الداخلية)، `auth` (مستخدمو Supabase الحقيقيون — ضروريون). **لا تشمل** مخططات Supabase
  الداخلية (`storage`/`vault`/`realtime`/`supabase_functions`/إلخ) — التطبيق لا يستخدمها أصلاً،
  وهي مُعاد تجهيزها تلقائياً بنفس الشكل من صورة Docker نفسها بأي بيئة هدف.

```bash
scripts/restore-db.sh backups/rotopa_backup_<...>.dump
PGCONTAINER=<container> scripts/restore-db.sh <ملف>
PGURL="postgres://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" scripts/restore-db.sh <ملف>
```

**مهم — الاستعادة تكون على قاعدة قائمة فعلاً ومُهيَّأة بمخططات روتوبا (`supabase/migrations/`
مُطبَّقة عليها مسبقاً على الأقل مرة)، لا قاعدة فارغة تماماً.** جُرِّب مباشرة: حذف القاعدة وإعادة
إنشائها من الصفر قبل الاستعادة يفقد تهيئة Supabase نفسها (الإضافات، المخططات الداخلية) وينتج عشرات
الأخطاء — أما الاستعادة "في مكانها" (`pg_restore --clean --if-exists`) على قاعدة مُهيَّأة أصلاً
فتعمل بلا أخطاء تقريباً. السكربت يطلب كتابة اسم القاعدة تأكيداً قبل أي تنفيذ (نفس مبدأ التأكيد
بالإجراءات الحساسة بالتطبيق نفسه).

**تحقّق دوري تلقائي من موثوقية الاستعادة**: `.github/workflows/backup-verify.yml` — يعمل أسبوعياً
(وبأمر يدوي من تبويب Actions) — يطبّق الهجرات على قاعدتين، ينسخ الأولى احتياطياً، يستعيدها على
الثانية، **ثم يُعيد تشغيل كل ملفات الاختبار (26 ملفاً) على القاعدة المُستعادة** — أقوى تحقّق ممكن،
لأنه يفحص كل دالة وصلاحية ومحفّز، لا مجرد عدّ صفوف.

## 4. المراقبة

هذا المشروع بلا خادم backend خاص (Supabase + PostgREST + Cloudflare Pages مباشرة) فلا حاجة لأداة
APM تقليدية — الاعتماد على أدوات المنصتين نفسيهما:

| ماذا | أين |
|---|---|
| أداء قاعدة البيانات (CPU، اتصالات، استعلامات بطيئة) | Supabase Dashboard → Database → Reports |
| نسخ احتياطي تلقائي مُدار (منفصل عن `scripts/backup-db.sh`، مُكمِّل له) | Supabase Dashboard → Database → Backups — فعِّل Point-in-Time Recovery على خطة الإنتاج |
| أخطاء/استخدام الواجهة | Cloudflare Pages → Analytics |
| توفّر الخادم (uptime) | أي أداة نبض خارجية (مثلاً UptimeRobot) على `https://<ref>.supabase.co/rest/v1/` — يرجع 200 دائماً إن كانت القاعدة تعمل |
| موثوقية الاستعادة | `backup-verify.yml` الأسبوعي — GitHub يرسل بريداً تلقائياً عند فشله |
| سجل كل تغيير بالبيانات | صفحة **سجل التدقيق** بالتطبيق نفسه (`/audit-log`) |

## دليل الاسترداد الطارئ

عند فقدان بيانات أو تعطّل قاعدة الإنتاج:

1. **لا تلمس القاعدة المتضررة قبل أخذ نسخة من حالتها الحالية** (حتى لو تالفة) — `scripts/backup-db.sh`
   ضدها أولاً، تحسباً لحاجتها لاحقاً بالتحقيق.
2. **حدّد أحدث نسخة سليمة**: إما من Supabase Dashboard → Backups (استعادة نقطة زمنية عبر لوحتهم
   مباشرة — الأسرع لبيانات الإنتاج الحقيقية) أو من `backups/` المحلية إن كانت أحدث/الوحيدة المتاحة.
3. **الاستعادة**: `PGURL=<رابط قاعدة الإنتاج> scripts/restore-db.sh <ملف النسخة>` — يطلب كتابة اسم
   القاعدة تأكيداً. **لا تُشغَّل هذه الخطوة إلا بعد التأكد من الخطوة 1.**
4. **تحقّق قبل الإعلان أنها انتهت**: `PGURL=<رابط قاعدة الإنتاج> bash supabase/tests/run-tests-only.sh`
   — **ليس** `supabase/tests/run.sh` (ذاك يعيد تطبيق الهجرات من الصفر ويفترض قاعدة فارغة، يفسد قاعدة
   استُعيدت فعلاً بمحتواها). `run-tests-only.sh` يكتفي بتشغيل ملفات الاختبار كما هي على القاعدة
   الموجودة — نفس السكربت يستخدمه `backup-verify.yml` أسبوعياً. لا تكتفِ بعدّ الصفوف، شغّل الاختبارات
   الحقيقية.
5. **أعد ربط تسجيل الدخول إن احتاج الأمر**: نسخة قديمة تحمل مستخدمي `auth.users` بحالتهم وقت
   النسخ — أي مستخدم أُنشئ بعدها يحتاج إعادة تسجيل.
6. **بعد الاستقرار**: وثِّق ماذا حصل ولماذا (سبب حقيقي لا تخمين) — نفس مبدأ "سبب إلزامي" المعتمد
   بإعادة فتح الفترات المحاسبية بالتطبيق نفسه، لأن مثل هذا الحادث يستحق نفس مستوى التوثيق.
