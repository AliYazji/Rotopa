-- ============================================================================
-- Rotopa · Sector-specific chart-of-accounts templates (قطاع المؤسسة)
--
-- Every organization used to get the exact same restaurant+hotel chart of
-- accounts (20250911003800_default_coa.sql), regardless of what kind of
-- business it actually is. The user wants to offer this as a product to
-- other sectors too (factories, pharmacies, cafes, supermarkets, salons,
-- produce shops, chalets/hotels, equipment stores) — each with its own
-- accounts, and eventually its own UI/module customization.
--
-- This migration builds the FIRST new sector as a real, complete template
-- (مصانع وشركات / manufacturing companies — designed from general cost-
-- accounting practice, not a source file this time, per explicit user
-- choice), and the dispatch mechanism every future sector plugs into:
-- organizations.sector picks which app.seed_coa_<sector>() function runs.
-- The other 6 named sectors are recorded in the check constraint (so
-- choosing them later needs no ALTER TABLE) but have no template yet —
-- create_organization() falls back to the existing restaurant/hotel chart
-- for any sector without its own seed function, which is functional but
-- not tailored; each sector gets a real template as its own follow-up.
-- ============================================================================

alter table organizations add column sector text not null default 'restaurant_hotel'
  check (sector in (
    'restaurant_hotel',   -- مطاعم وفنادق (الافتراضي الأصلي، مبني بالكامل)
    'manufacturing',      -- مصانع وشركات (مبني بهذا الترحيل)
    'pharmacy',           -- صيدليات
    'cafe',                -- كافيهات
    'supermarket',        -- سوبر ماركت
    'salon',               -- صالونات
    'produce',            -- محلات خضار وفواكه
    'chalets_hotels',     -- شاليهات وفنادق
    'equipment_store'      -- محلات أجهزة ومعدات
  ));
comment on column organizations.sector is
  'Picks which app.seed_coa_<sector>() chart-of-accounts template create_organization() seeds. Only restaurant_hotel and manufacturing have real templates so far — everything else falls back to restaurant_hotel until built.';

-- ---------------------------------------------------------------------------
-- app.seed_coa_manufacturing() — same shape/idiom as
-- app.seed_default_chart_of_accounts() (categories, then a data-driven
-- accounts loop resolving parent_id by code lookup), just a different
-- chart: raw materials -> work-in-process -> finished goods, direct
-- materials/direct labor/overhead as separate cost lines (mirroring the
-- manufacturing_orders module's own labor/equipment/subcontractor/other
-- cost fields), local + import supplier control groups, distributor
-- receivables alongside ordinary customers.
-- ---------------------------------------------------------------------------
create or replace function app.seed_coa_manufacturing(p_org uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare r record;
begin
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance, sort_order) values
    (p_org, 'CASH',       'النقد وما يعادله',                          'balance_sheet',   'asset',     'debit',  10),
    (p_org, 'CHQR',       'شيكات وأوراق قبض',                         'balance_sheet',   'asset',     'debit',  20),
    (p_org, 'ARCUST',     'الذمم المدينة (عملاء وموزعون)',            'balance_sheet',   'asset',     'debit',  30),
    (p_org, 'AREMP',      'ذمم الموظفين',                             'balance_sheet',   'asset',     'debit',  40),
    (p_org, 'INV',        'المخزون',                                  'balance_sheet',   'asset',     'debit',  50),
    (p_org, 'TAXR',       'الضرائب القابلة للاسترداد',                 'balance_sheet',   'asset',     'debit',  60),
    (p_org, 'PPD',        'سلف ومصروفات مدفوعة مقدمًا',                'balance_sheet',   'asset',     'debit',  70),
    (p_org, 'OCA',        'أصول متداولة وحسابات وسيطة أخرى',           'balance_sheet',   'asset',     'debit',  80),
    (p_org, 'PPE',        'الأصول الثابتة (بالتكلفة)',                 'balance_sheet',   'asset',     'debit',  90),
    (p_org, 'ACCDEP',     'مجمع إهلاك الأصول الثابتة',                 'balance_sheet',   'asset',     'debit', 100),
    (p_org, 'INTANG',     'الأصول غير الملموسة',                       'balance_sheet',   'asset',     'debit', 110),
    (p_org, 'LTDEP',      'تأمينات وأصول طويلة الأجل',                 'balance_sheet',   'asset',     'debit', 120),
    (p_org, 'AP',         'الموردون',                                  'balance_sheet',   'liability', 'credit', 130),
    (p_org, 'APOTH',      'دائنون وحسابات دفع أخرى',                   'balance_sheet',   'liability', 'credit', 140),
    (p_org, 'CHQP',       'شيكات وأوراق دفع',                          'balance_sheet',   'liability', 'credit', 150),
    (p_org, 'TAXP',       'ضرائب ورسوم مستحقة',                        'balance_sheet',   'liability', 'credit', 160),
    (p_org, 'ACCR',       'مصروفات مستحقة',                            'balance_sheet',   'liability', 'credit', 170),
    (p_org, 'EMPLIAB',    'التزامات الموظفين',                         'balance_sheet',   'liability', 'credit', 180),
    (p_org, 'CUSTADV',    'دفعات العملاء المقدمة',                     'balance_sheet',   'liability', 'credit', 190),
    (p_org, 'STFIN',      'تمويلات قصيرة الأجل',                       'balance_sheet',   'liability', 'credit', 200),
    (p_org, 'OCL',        'التزامات متداولة أخرى',                     'balance_sheet',   'liability', 'credit', 210),
    (p_org, 'LTL',        'الالتزامات غير المتداولة',                  'balance_sheet',   'liability', 'credit', 220),
    (p_org, 'CAP',        'رأس المال',                                 'balance_sheet',   'equity',    'credit', 230),
    (p_org, 'CURACC',     'الحسابات الجارية للملاك والشركاء',          'balance_sheet',   'equity',    'credit', 240),
    (p_org, 'RE',         'الأرباح والخسائر المتراكمة',                'balance_sheet',   'equity',    'credit', 250),
    (p_org, 'CYRESULT',   'نتيجة السنة الحالية',                       'balance_sheet',   'equity',    'credit', 260),
    (p_org, 'DRAW',       'المسحوبات والتوزيعات',                      'balance_sheet',   'equity',    'credit', 270),
    (p_org, 'RESV',       'الاحتياطيات',                               'balance_sheet',   'equity',    'credit', 280),
    (p_org, 'PRODMAT',    'المواد المباشرة المستهلكة',                 'income_statement','expense',   'debit', 290),
    (p_org, 'PRODLABOR',  'الأجور المباشرة',                           'income_statement','expense',   'debit', 300),
    (p_org, 'PRODOH',     'التكاليف الصناعية غير المباشرة',            'income_statement','expense',   'debit', 310),
    (p_org, 'INVVAR',     'فروقات وهالك المخزون',                      'income_statement','expense',   'debit', 320),
    (p_org, 'STAFFCOST',  'تكاليف الموظفين غير الإنتاجيين',            'income_statement','expense',   'debit', 330),
    (p_org, 'OCCUP',      'مصروفات الإشغال والطاقة (الإدارية)',        'income_statement','expense',   'debit', 340),
    (p_org, 'MAINT',      'مصروفات الصيانة العامة',                    'income_statement','expense',   'debit', 350),
    (p_org, 'MKTG',       'مصروفات البيع والتسويق',                    'income_statement','expense',   'debit', 360),
    (p_org, 'ADMIN',      'المصروفات الإدارية والعمومية',              'income_statement','expense',   'debit', 370),
    (p_org, 'DEPR',       'مصروف الإهلاك والإطفاء (الإداري)',          'income_statement','expense',   'debit', 380),
    (p_org, 'VEHIC',      'مصروفات النقل والتوزيع',                    'income_statement','expense',   'debit', 390),
    (p_org, 'OTHEXP',     'خسائر ومصروفات تشغيلية أخرى',               'income_statement','expense',   'debit', 400),
    (p_org, 'FIN',        'تكاليف التمويل',                            'income_statement','expense',   'debit', 410),
    (p_org, 'INCTAX',     'ضرائب على الدخل',                           'income_statement','expense',   'debit', 420),
    (p_org, 'PRODREV',    'مبيعات المنتجات',                           'income_statement','income',    'credit', 430),
    (p_org, 'OTH_OP_REV', 'إيرادات تشغيلية أخرى',                      'income_statement','income',    'credit', 440),
    (p_org, 'CONTRA_REV', 'حسابات مقابلة للإيراد',                     'income_statement','income',    'credit', 450),
    (p_org, 'OTH_INC',    'إيرادات ومكاسب أخرى',                       'income_statement','income',    'credit', 460)
  on conflict (org_id, code) do nothing;

  for r in select * from (values
    ('10000', null, 'الأصول', 'debit', false, null, false, null),
    ('11000', '10000', 'الأصول المتداولة', 'debit', false, null, false, null),
    ('11100', '11000', 'الصناديق والنقدية', 'debit', false, null, false, null),
    ('11101', '11100', 'الصندوق العام - شيكل', 'debit', true, 'CASH', false, null),
    ('11102', '11100', 'الصندوق العام - دولار', 'debit', true, 'CASH', false, null),
    ('11103', '11100', 'عهدة نقدية مستديمة', 'debit', true, 'CASH', false, null),
    ('11200', '11000', 'البنوك', 'debit', false, null, false, null),
    ('11201', '11200', 'بنك - حساب جاري شيكل', 'debit', true, 'CASH', false, null),
    ('11202', '11200', 'بنك - حساب جاري دولار', 'debit', true, 'CASH', false, null),
    ('11203', '11200', 'بنك - حساب توفير', 'debit', true, 'CASH', false, null),
    ('11300', '11000', 'شيكات وأوراق قبض', 'debit', false, null, false, null),
    ('11301', '11300', 'شيكات برسم التحصيل - شيكل', 'debit', true, 'CHQR', false, null),
    ('11302', '11300', 'شيكات برسم التحصيل - دولار', 'debit', true, 'CHQR', false, null),
    ('11303', '11300', 'أوراق قبض (كمبيالات)', 'debit', true, 'CHQR', false, null),
    ('11400', '11000', 'الذمم المدينة', 'debit', false, null, false, null),
    ('11401', '11400', 'ذمم العملاء - حساب مراقبة', 'debit', false, 'ARCUST', true, 'customers'),
    ('11402', '11400', 'ذمم موزعين وممثلين تجاريين', 'debit', true, 'ARCUST', false, null),
    ('11403', '11400', 'مخصص الديون المشكوك في تحصيلها', 'credit', true, 'ARCUST', false, null),
    ('11500', '11000', 'ذمم الموظفين', 'debit', false, 'AREMP', true, 'employees'),
    ('11600', '11000', 'المخزون', 'debit', false, null, false, null),
    ('11601', '11600', 'مخزون المواد الخام', 'debit', true, 'INV', false, null),
    ('11602', '11600', 'مخزون مواد التعبئة والتغليف', 'debit', true, 'INV', false, null),
    ('11603', '11600', 'مخزون تحت التشغيل (إنتاج غير تام)', 'debit', true, 'INV', false, null),
    ('11604', '11600', 'مخزون البضاعة تامة الصنع', 'debit', true, 'INV', false, null),
    ('11605', '11600', 'مخزون قطع الغيار والصيانة', 'debit', true, 'INV', false, null),
    ('11606', '11600', 'مخزون الوقود والزيوت الصناعية', 'debit', true, 'INV', false, null),
    ('11607', '11600', 'بضاعة بالطريق', 'debit', true, 'INV', false, null),
    ('11700', '11000', 'الضرائب القابلة للاسترداد', 'debit', false, null, false, null),
    ('11701', '11700', 'ضريبة قيمة مضافة - مدخلات', 'debit', true, 'TAXR', false, null),
    ('11702', '11700', 'دفعات ضريبة دخل مقدمة', 'debit', true, 'TAXR', false, null),
    ('11703', '11700', 'ضريبة مخصومة من المنبع لنا', 'debit', true, 'TAXR', false, null),
    ('11800', '11000', 'سلف ومصروفات مدفوعة مقدمًا', 'debit', false, null, false, null),
    ('11801', '11800', 'سلف الموظفين', 'debit', true, 'PPD', false, null),
    ('11802', '11800', 'دفعات مقدمة للموردين', 'debit', true, 'PPD', false, null),
    ('11803', '11800', 'إيجار مدفوع مقدمًا', 'debit', true, 'PPD', false, null),
    ('11804', '11800', 'تأمين مدفوع مقدمًا', 'debit', true, 'PPD', false, null),
    ('11805', '11800', 'اشتراكات وبرامج مدفوعة مقدمًا', 'debit', true, 'PPD', false, null),
    ('11900', '11000', 'أصول متداولة وحسابات وسيطة أخرى', 'debit', false, null, false, null),
    ('11901', '11900', 'تحويلات نقدية قيد التسوية', 'both', true, 'OCA', false, null),
    ('11902', '11900', 'مصاريف معلقة لحين التصنيف', 'debit', true, 'OCA', false, null),
    ('20000', null, 'الأصول غير المتداولة', 'debit', false, null, false, null),
    ('21000', '20000', 'الأصول الثابتة بالتكلفة', 'debit', false, null, false, null),
    ('21100', '21000', 'الأراضي والمباني', 'debit', false, null, false, null),
    ('21101', '21100', 'الأراضي', 'debit', true, 'PPE', false, null),
    ('21102', '21100', 'المباني والمستودعات', 'debit', true, 'PPE', false, null),
    ('21103', '21100', 'تحسينات على عقار مستأجر', 'debit', true, 'PPE', false, null),
    ('21200', '21000', 'آلات ومعدات الإنتاج', 'debit', false, null, false, null),
    ('21201', '21200', 'آلات وخطوط الإنتاج', 'debit', true, 'PPE', false, null),
    ('21202', '21200', 'معدات المناولة والرفع', 'debit', true, 'PPE', false, null),
    ('21203', '21200', 'قوالب وأدوات تصنيع', 'debit', true, 'PPE', false, null),
    ('21300', '21000', 'أثاث وتجهيزات', 'debit', false, null, false, null),
    ('21301', '21300', 'أثاث المكاتب', 'debit', true, 'PPE', false, null),
    ('21302', '21300', 'تجهيزات المستودعات', 'debit', true, 'PPE', false, null),
    ('21400', '21000', 'وسائل النقل', 'debit', false, null, false, null),
    ('21401', '21400', 'شاحنات ومركبات نقل', 'debit', true, 'PPE', false, null),
    ('21402', '21400', 'سيارات إدارية', 'debit', true, 'PPE', false, null),
    ('21500', '21000', 'أجهزة الحاسوب والأنظمة', 'debit', false, null, false, null),
    ('21501', '21500', 'أجهزة الحاسوب والطابعات', 'debit', true, 'PPE', false, null),
    ('21502', '21500', 'أنظمة وبرمجيات تشغيلية', 'debit', true, 'PPE', false, null),
    ('21503', '21500', 'كاميرات وأنظمة مراقبة', 'debit', true, 'PPE', false, null),
    ('21600', '21000', 'معدات كهربائية وطاقة', 'debit', false, null, false, null),
    ('21601', '21600', 'مولدات كهربائية', 'debit', true, 'PPE', false, null),
    ('21602', '21600', 'محولات وأنظمة طاقة', 'debit', true, 'PPE', false, null),
    ('22000', '20000', 'مجمع إهلاك الأصول الثابتة', 'credit', false, null, false, null),
    ('22101', '22000', 'مجمع إهلاك المباني', 'credit', true, 'ACCDEP', false, null),
    ('22201', '22000', 'مجمع إهلاك آلات ومعدات الإنتاج', 'credit', true, 'ACCDEP', false, null),
    ('22301', '22000', 'مجمع إهلاك الأثاث والتجهيزات', 'credit', true, 'ACCDEP', false, null),
    ('22401', '22000', 'مجمع إهلاك وسائل النقل', 'credit', true, 'ACCDEP', false, null),
    ('22501', '22000', 'مجمع إهلاك أجهزة الحاسوب والأنظمة', 'credit', true, 'ACCDEP', false, null),
    ('22601', '22000', 'مجمع إهلاك المعدات الكهربائية', 'credit', true, 'ACCDEP', false, null),
    ('23000', '20000', 'الأصول غير الملموسة', 'debit', false, null, false, null),
    ('23101', '23000', 'براءات اختراع وتراخيص إنتاج', 'debit', true, 'INTANG', false, null),
    ('23102', '23000', 'برامج وأنظمة محاسبية مملوكة', 'debit', true, 'INTANG', false, null),
    ('23901', '23000', 'مجمع إطفاء الأصول غير الملموسة', 'credit', true, 'INTANG', false, null),
    ('24000', '20000', 'تأمينات وأصول طويلة الأجل', 'debit', false, null, false, null),
    ('24101', '24000', 'تأمينات مستردة طويلة الأجل', 'debit', true, 'LTDEP', false, null),
    ('30000', null, 'الالتزامات', 'credit', false, null, false, null),
    ('31000', '30000', 'الالتزامات المتداولة', 'credit', false, null, false, null),
    ('31100', '31000', 'الموردون', 'credit', false, null, false, null),
    ('31101', '31100', 'موردو المواد الخام - محليون - حساب مراقبة', 'credit', false, 'AP', true, 'suppliers'),
    ('31102', '31100', 'موردو المواد الخام - مستوردون - حساب مراقبة', 'credit', false, 'AP', true, 'suppliers'),
    ('31200', '31000', 'دائنون وحسابات دفع أخرى', 'credit', false, null, false, null),
    ('31201', '31200', 'دائنون متنوعون', 'credit', true, 'APOTH', false, null),
    ('31202', '31200', 'مشتريات مستلمة غير مفوترة', 'credit', true, 'APOTH', false, null),
    ('31300', '31000', 'شيكات وأوراق دفع', 'credit', false, null, false, null),
    ('31301', '31300', 'شيكات تحت الدفع - شيكل', 'credit', true, 'CHQP', false, null),
    ('31302', '31300', 'شيكات تحت الدفع - دولار', 'credit', true, 'CHQP', false, null),
    ('31303', '31300', 'أوراق دفع (كمبيالات)', 'credit', true, 'CHQP', false, null),
    ('31400', '31000', 'ضرائب ورسوم مستحقة', 'credit', false, null, false, null),
    ('31401', '31400', 'ضريبة قيمة مضافة - مخرجات', 'credit', true, 'TAXP', false, null),
    ('31402', '31400', 'صافي ضريبة القيمة المضافة المستحقة', 'credit', true, 'TAXP', false, null),
    ('31403', '31400', 'ضريبة دخل مستحقة', 'credit', true, 'TAXP', false, null),
    ('31404', '31400', 'ضرائب مقتطعة من الغير مستحقة للجهة الضريبية', 'credit', true, 'TAXP', false, null),
    ('31405', '31400', 'رسوم جمركية مستحقة', 'credit', true, 'TAXP', false, null),
    ('31500', '31000', 'مصروفات مستحقة', 'credit', false, null, false, null),
    ('31501', '31500', 'رواتب وأجور مستحقة', 'credit', true, 'ACCR', false, null),
    ('31502', '31500', 'إيجارات مستحقة', 'credit', true, 'ACCR', false, null),
    ('31503', '31500', 'كهرباء ومياه واتصالات مستحقة', 'credit', true, 'ACCR', false, null),
    ('31504', '31500', 'أتعاب مهنية مستحقة', 'credit', true, 'ACCR', false, null),
    ('31505', '31500', 'عمولات مستحقة', 'credit', true, 'ACCR', false, null),
    ('31600', '31000', 'التزامات الموظفين', 'credit', false, null, false, null),
    ('31601', '31600', 'صافي رواتب مستحقة للموظفين', 'credit', true, 'EMPLIAB', false, null),
    ('31602', '31600', 'استقطاعات موظفين مستحقة', 'credit', true, 'EMPLIAB', false, null),
    ('31603', '31600', 'مخصص مكافأة نهاية الخدمة - متداول', 'credit', true, 'EMPLIAB', false, null),
    ('31604', '31600', 'مخصص إجازات مستحقة', 'credit', true, 'EMPLIAB', false, null),
    ('31700', '31000', 'دفعات العملاء المقدمة', 'credit', false, null, false, null),
    ('31701', '31700', 'دفعات مقدمة من عملاء', 'credit', true, 'CUSTADV', false, null),
    ('31702', '31700', 'عربون تعاقدات توريد', 'credit', true, 'CUSTADV', false, null),
    ('31800', '31000', 'تمويلات قصيرة الأجل', 'credit', false, null, false, null),
    ('31801', '31800', 'تسهيلات وسحب على المكشوف', 'credit', true, 'STFIN', false, null),
    ('31802', '31800', 'قروض قصيرة الأجل', 'credit', true, 'STFIN', false, null),
    ('31803', '31800', 'الجزء المتداول من القروض طويلة الأجل', 'credit', true, 'STFIN', false, null),
    ('31900', '31000', 'التزامات متداولة أخرى', 'credit', false, null, false, null),
    ('31901', '31900', 'اعتمادات مستندية قيد التسوية', 'credit', true, 'OCL', false, null),
    ('31902', '31900', 'تأمينات موردين وعملاء مستردة', 'credit', true, 'OCL', false, null),
    ('32000', '30000', 'الالتزامات غير المتداولة', 'credit', false, null, false, null),
    ('32101', '32000', 'قروض طويلة الأجل', 'credit', true, 'LTL', false, null),
    ('32102', '32000', 'التزامات عقود الإيجار طويلة الأجل', 'credit', true, 'LTL', false, null),
    ('32103', '32000', 'مخصص مكافأة نهاية الخدمة - طويل الأجل', 'credit', true, 'LTL', false, null),
    ('40000', null, 'حقوق الملكية', 'credit', false, null, false, null),
    ('41000', '40000', 'رأس المال', 'credit', false, null, false, null),
    ('41001', '41000', 'رأس مال المالك', 'credit', true, 'CAP', false, null),
    ('41002', '41000', 'رأس مال شريك آخر', 'credit', true, 'CAP', false, null),
    ('42000', '40000', 'الحسابات الجارية للملاك والشركاء', 'both', false, null, false, null),
    ('42001', '42000', 'جاري المالك', 'both', true, 'CURACC', false, null),
    ('42002', '42000', 'جاري الشريك', 'both', true, 'CURACC', false, null),
    ('43000', '40000', 'الأرباح والخسائر المتراكمة', 'credit', false, null, false, null),
    ('43001', '43000', 'أرباح وخسائر سنوات سابقة', 'credit', true, 'RE', false, null),
    ('44000', '40000', 'نتيجة السنة الحالية', 'credit', false, null, false, null),
    ('44001', '44000', 'صافي ربح أو خسارة السنة الحالية', 'both', true, 'CYRESULT', false, null),
    ('45000', '40000', 'المسحوبات والتوزيعات', 'debit', false, null, false, null),
    ('45001', '45000', 'مسحوبات المالك', 'debit', true, 'DRAW', false, null),
    ('45002', '45000', 'مسحوبات الشريك', 'debit', true, 'DRAW', false, null),
    ('46000', '40000', 'الاحتياطيات', 'credit', false, null, false, null),
    ('46001', '46000', 'احتياطي عام', 'credit', true, 'RESV', false, null),
    ('46002', '46000', 'احتياطي إحلال وتجديد آلات', 'credit', true, 'RESV', false, null),
    ('50000', null, 'التكاليف والمصروفات', 'debit', false, null, false, null),
    ('51000', '50000', 'تكلفة الإنتاج', 'debit', false, null, false, null),
    ('51100', '51000', 'المواد المباشرة المستهلكة', 'debit', false, null, false, null),
    ('51101', '51100', 'استهلاك مواد خام', 'debit', true, 'PRODMAT', false, null),
    ('51102', '51100', 'استهلاك مواد تعبئة وتغليف', 'debit', true, 'PRODMAT', false, null),
    ('51200', '51000', 'الأجور المباشرة', 'debit', false, null, false, null),
    ('51201', '51200', 'أجور عمال الإنتاج المباشرين', 'debit', true, 'PRODLABOR', false, null),
    ('51300', '51000', 'التكاليف الصناعية غير المباشرة', 'debit', false, null, false, null),
    ('51301', '51300', 'إيجار المصنع', 'debit', true, 'PRODOH', false, null),
    ('51302', '51300', 'كهرباء ومياه المصنع', 'debit', true, 'PRODOH', false, null),
    ('51303', '51300', 'صيانة آلات ومعدات الإنتاج', 'debit', true, 'PRODOH', false, null),
    ('51304', '51300', 'أجور مقاولي الإنتاج من الباطن', 'debit', true, 'PRODOH', false, null),
    ('51305', '51300', 'تكاليف صناعية أخرى', 'debit', true, 'PRODOH', false, null),
    ('51306', '51300', 'إهلاك آلات ومعدات الإنتاج', 'debit', true, 'PRODOH', false, null),
    ('51307', '51300', 'أجور إشراف وعمالة غير مباشرة', 'debit', true, 'PRODOH', false, null),
    ('51400', '51000', 'فروقات وهالك المخزون', 'debit', false, null, false, null),
    ('51401', '51400', 'هالك وتالف مواد خام', 'debit', true, 'INVVAR', false, null),
    ('51402', '51400', 'عجز وفروقات جرد المخزون', 'debit', true, 'INVVAR', false, null),
    ('51403', '51400', 'زيادة مخزون مكتشفة بالجرد', 'credit', true, 'INVVAR', false, null),
    ('52000', '50000', 'تكاليف الموظفين غير الإنتاجيين', 'debit', false, null, false, null),
    ('52101', '52000', 'رواتب وأجور إدارية', 'debit', true, 'STAFFCOST', false, null),
    ('52102', '52000', 'رواتب وأجور مبيعات', 'debit', true, 'STAFFCOST', false, null),
    ('52103', '52000', 'عمل إضافي وحوافز', 'debit', true, 'STAFFCOST', false, null),
    ('52104', '52000', 'بدلات نقل ووجبات ومزايا موظفين', 'debit', true, 'STAFFCOST', false, null),
    ('52105', '52000', 'علاج وتأمين صحي للموظفين', 'debit', true, 'STAFFCOST', false, null),
    ('52106', '52000', 'مصروف مكافأة نهاية الخدمة', 'debit', true, 'STAFFCOST', false, null),
    ('52107', '52000', 'مساهمات ورسوم مرتبطة بالرواتب', 'debit', true, 'STAFFCOST', false, null),
    ('53000', '50000', 'مصروفات الإشغال والطاقة (الإدارية)', 'debit', false, null, false, null),
    ('53101', '53000', 'إيجار المكاتب الإدارية', 'debit', true, 'OCCUP', false, null),
    ('53102', '53000', 'كهرباء ومياه المكاتب', 'debit', true, 'OCCUP', false, null),
    ('53103', '53000', 'مصاريف النظافة والحراسة الإدارية', 'debit', true, 'OCCUP', false, null),
    ('53200', '53000', 'مصروفات الصيانة العامة', 'debit', false, null, false, null),
    ('53201', '53200', 'صيانة المباني الإدارية', 'debit', true, 'MAINT', false, null),
    ('53202', '53200', 'صيانة أجهزة الحاسوب والأنظمة', 'debit', true, 'MAINT', false, null),
    ('53203', '53200', 'صيانة المركبات', 'debit', true, 'MAINT', false, null),
    ('53204', '53200', 'صيانة أنظمة الكهرباء والطاقة', 'debit', true, 'MAINT', false, null),
    ('53300', '53000', 'مصروفات البيع والتسويق', 'debit', false, null, false, null),
    ('53301', '53300', 'إعلانات ووسائل تواصل اجتماعي', 'debit', true, 'MKTG', false, null),
    ('53302', '53300', 'معارض ومؤتمرات تجارية', 'debit', true, 'MKTG', false, null),
    ('53303', '53300', 'عمولات مندوبي ووسطاء المبيعات', 'debit', true, 'MKTG', false, null),
    ('53304', '53300', 'مصاريف شحن وتوصيل المبيعات', 'debit', true, 'MKTG', false, null),
    ('53305', '53300', 'عينات مجانية وترويج', 'debit', true, 'MKTG', false, null),
    ('53400', '53000', 'المصروفات الإدارية والعمومية', 'debit', false, null, false, null),
    ('53401', '53400', 'هاتف واتصالات', 'debit', true, 'ADMIN', false, null),
    ('53402', '53400', 'إنترنت', 'debit', true, 'ADMIN', false, null),
    ('53403', '53400', 'اشتراكات وصيانة برامج وأنظمة', 'debit', true, 'ADMIN', false, null),
    ('53404', '53400', 'تراخيص وتصاريح صناعية', 'debit', true, 'ADMIN', false, null),
    ('53405', '53400', 'رسوم معاملات رسمية وبلدية', 'debit', true, 'ADMIN', false, null),
    ('53406', '53400', 'عمولات ومصاريف بنكية', 'debit', true, 'ADMIN', false, null),
    ('53407', '53400', 'أتعاب محاسبة وتدقيق ومراجعة', 'debit', true, 'ADMIN', false, null),
    ('53408', '53400', 'أتعاب قانونية واستشارات', 'debit', true, 'ADMIN', false, null),
    ('53409', '53400', 'قرطاسية ومطبوعات مكتبية', 'debit', true, 'ADMIN', false, null),
    ('53410', '53400', 'ضيافة ومصاريف اجتماعات', 'debit', true, 'ADMIN', false, null),
    ('53411', '53400', 'مواصلات وسفر ومهمات', 'debit', true, 'ADMIN', false, null),
    ('53412', '53400', 'أمن وحراسة', 'debit', true, 'ADMIN', false, null),
    ('53413', '53400', 'تأمين حريق وسرقة وممتلكات', 'debit', true, 'ADMIN', false, null),
    ('53414', '53400', 'تأمين مسؤولية المنتج', 'debit', true, 'ADMIN', false, null),
    ('53415', '53400', 'مصروفات متنوعة محدودة', 'debit', true, 'ADMIN', false, null),
    ('53500', '53000', 'مصروف الإهلاك والإطفاء (الإداري)', 'debit', false, null, false, null),
    ('53501', '53500', 'إهلاك المباني الإدارية', 'debit', true, 'DEPR', false, null),
    ('53502', '53500', 'إهلاك الأثاث والتجهيزات', 'debit', true, 'DEPR', false, null),
    ('53503', '53500', 'إهلاك أجهزة الحاسوب والأنظمة', 'debit', true, 'DEPR', false, null),
    ('53504', '53500', 'إطفاء البرامج وبراءات الاختراع', 'debit', true, 'DEPR', false, null),
    ('53600', '53000', 'مصروفات النقل والتوزيع', 'debit', false, null, false, null),
    ('53601', '53600', 'وقود وزيوت المركبات', 'debit', true, 'VEHIC', false, null),
    ('53602', '53600', 'ترخيص وتأمين المركبات', 'debit', true, 'VEHIC', false, null),
    ('53603', '53600', 'مصاريف شحن ونقل مستورد', 'debit', true, 'VEHIC', false, null),
    ('53700', '53000', 'خسائر ومصروفات تشغيلية أخرى', 'debit', false, null, false, null),
    ('53701', '53700', 'عجز الصندوق والنقدية', 'debit', true, 'OTHEXP', false, null),
    ('53702', '53700', 'ديون معدومة ومشكوك فيها', 'debit', true, 'OTHEXP', false, null),
    ('53703', '53700', 'خسائر تلف أصول وممتلكات', 'debit', true, 'OTHEXP', false, null),
    ('53704', '53700', 'غرامات ومخالفات غير ضريبية', 'debit', true, 'OTHEXP', false, null),
    ('53705', '53700', 'تبرعات ومساعدات', 'debit', true, 'OTHEXP', false, null),
    ('53706', '53700', 'خسائر فروق عملة', 'debit', true, 'OTHEXP', false, null),
    ('53800', '53000', 'تكاليف التمويل', 'debit', false, null, false, null),
    ('53801', '53800', 'فوائد وعمولات القروض', 'debit', true, 'FIN', false, null),
    ('53802', '53800', 'تكلفة تمويل الاعتمادات المستندية', 'debit', true, 'FIN', false, null),
    ('53900', '53000', 'ضرائب على الدخل', 'debit', false, null, false, null),
    ('53901', '53900', 'مصروف ضريبة الدخل', 'debit', true, 'INCTAX', false, null),
    ('60000', null, 'الإيرادات', 'credit', false, null, false, null),
    ('61000', '60000', 'مبيعات المنتجات', 'credit', false, null, false, null),
    ('61101', '61000', 'مبيعات محلية', 'credit', true, 'PRODREV', false, null),
    ('61102', '61000', 'مبيعات تصدير', 'credit', true, 'PRODREV', false, null),
    ('61103', '61000', 'مبيعات تصنيع بالعقد لطرف ثالث', 'credit', true, 'PRODREV', false, null),
    ('62000', '60000', 'إيرادات تشغيلية أخرى', 'credit', false, null, false, null),
    ('62101', '62000', 'إيراد بيع مخلفات ومواد مستعملة', 'credit', true, 'OTH_OP_REV', false, null),
    ('62102', '62000', 'إيراد تأجير معدات أو مساحات', 'credit', true, 'OTH_OP_REV', false, null),
    ('62103', '62000', 'إيراد خدمات تصنيع لطرف ثالث', 'credit', true, 'OTH_OP_REV', false, null),
    ('63000', '60000', 'حسابات مقابلة للإيراد', 'debit', false, null, false, null),
    ('63101', '63000', 'خصم مسموح به للعملاء', 'debit', true, 'CONTRA_REV', false, null),
    ('63102', '63000', 'مردودات ومسموحات المبيعات', 'debit', true, 'CONTRA_REV', false, null),
    ('64000', '60000', 'إيرادات ومكاسب أخرى', 'credit', false, null, false, null),
    ('64101', '64000', 'خصم مكتسب من الموردين', 'credit', true, 'OTH_INC', false, null),
    ('64102', '64000', 'أرباح فروق عملة', 'credit', true, 'OTH_INC', false, null),
    ('64103', '64000', 'أرباح بيع أصول ثابتة', 'credit', true, 'OTH_INC', false, null),
    ('64104', '64000', 'زيادة الصندوق والنقدية', 'credit', true, 'OTH_INC', false, null),
    ('64105', '64000', 'إيرادات أخرى غير تشغيلية', 'credit', true, 'OTH_INC', false, null)
  ) as t(code, parent_code, name_ar, nature, is_postable, category_code, is_control, control_type)
  loop
    insert into accounts (org_id, code, name_ar, parent_id, category_id, nature, is_postable, is_control, control_type)
    values (
      p_org, r.code, r.name_ar,
      (select id from accounts where org_id = p_org and code = r.parent_code),
      (select id from account_categories where org_id = p_org and code = r.category_code),
      r.nature, r.is_postable, r.is_control, r.control_type
    )
    on conflict (org_id, code) do nothing;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_organization() — same as the true latest body (20250911003800),
-- plus one new p_sector parameter that picks which chart-of-accounts
-- template gets seeded. Dropping the old 5-parameter signature first: an
-- appended parameter is a genuinely different function identity to
-- Postgres, not a true replace (the exact bug this session already hit
-- twice — app.vat_rate(), then create_sales_invoice()).
-- ---------------------------------------------------------------------------
drop function if exists create_organization(text, text, text, text, int);

create or replace function create_organization(
  p_code text,
  p_name_ar text,
  p_base_currency_code text default 'NIS',
  p_base_currency_name_ar text default 'شيكل',
  p_fiscal_year_start_month int default 1,
  p_sector text default 'restaurant_hotel'
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_org uuid;
  v_cur uuid;
  v_role_owner uuid;
  v_role_acct  uuid;
  v_role_view  uuid;
  k text;
begin
  if auth.uid() is null then
    raise exception 'must be signed in to create an organization' using errcode = '42501';
  end if;

  insert into organizations (code, name_ar, fiscal_year_start_month, sector)
  values (p_code, p_name_ar, p_fiscal_year_start_month, coalesce(p_sector, 'restaurant_hotel'))
  returning id into v_org;

  insert into currencies (org_id, code, name_ar, is_base, decimal_places)
  values (v_org, p_base_currency_code, p_base_currency_name_ar, true, 2)
  returning id into v_cur;

  update organizations set base_currency_id = v_cur where id = v_org;

  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', true, 'rate', 0.16));

  -- dispatch to the sector's own chart-of-accounts template; anything
  -- without a real template yet falls back to restaurant_hotel (functional,
  -- just not tailored) rather than leaving the org with zero accounts
  if p_sector = 'manufacturing' then
    perform app.seed_coa_manufacturing(v_org);
  else
    perform app.seed_default_chart_of_accounts(v_org);
  end if;

  -- roles
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'owner',      'مالك',   true) returning id into v_role_owner;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'accountant', 'محاسب',  true) returning id into v_role_acct;
  insert into roles (org_id, code, name_ar, is_system) values
    (v_org, 'viewer',     'مطّلع',  true) returning id into v_role_view;

  perform set_config('app.skip_role_guard', 'on', true);
  insert into role_permissions (role_id, permission_key)
    select v_role_owner, key from permissions;
  insert into role_permissions (role_id, permission_key)
    select v_role_acct, key from permissions
    where key not in ('org.manage','roles.write','members.write');
  insert into role_permissions (role_id, permission_key) values
    (v_role_view, 'audit.read'), (v_role_view, 'reports.view');
  perform set_config('app.skip_role_guard', 'off', true);

  insert into memberships (org_id, user_id, role_id, is_owner)
  values (v_org, auth.uid(), v_role_owner, true);

  perform create_fiscal_year(v_org, extract(year from now())::int);

  return v_org;
end;
$$;
