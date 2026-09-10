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
