-- ============================================================================
-- Rotopa · Default chart of accounts (restaurant + hotel)
--
-- Every new organization used to start with ZERO accounts — create_organi-
-- zation() only ever set up roles/currency/fiscal year, leaving the whole
-- chart of accounts to be built by hand from /accounts. The user supplied a
-- proposed chart (Downloads/دليل_الحسابات_الصحيح.xlsx, 285 accounts) after
-- comparing it against the one real org's existing 114-account chart (a
-- direct, uncurated ETL carry-over from the legacy backup) and confirming
-- it fixes real problems there: individual dealer names created as plain
-- GL accounts instead of dealer sub-accounts, orphaned root-level leaf
-- accounts, a "Car 1" top-level section parallel to Assets/Liabilities,
-- placeholder legacy account names, and near-universal 'both' nature
-- instead of a real debit/credit designation. It's also deliberately
-- designed around this system's own architecture: perpetual inventory,
-- explicit control accounts for customers/suppliers, and "don't bake the
-- tax rate into the account name — set it in tax settings" (exactly the
-- configurable-tax feature already built this session).
--
-- FIVE "- حساب مراقبة" (control account) leaf rows from the source file
-- were turned into GROUP accounts here instead (is_postable=false,
-- is_control=true) — a deliberate deviation from what the source file
-- literally said, not an oversight: create_dealer() (20250911001200) auto-
-- creates ONE REAL leaf GL sub-account PER dealer under a chosen non-
-- postable parent — this system never implements a single shared control
-- account backed by an external subledger (which is what the source file's
-- own "العملاء والموردون" note assumed). Each such group still needs a real
-- category_id despite being non-postable, because create_dealer() copies
-- the PARENT's category_id onto every dealer account it creates — without
-- it, every customer/supplier/employee sub-account would silently vanish
-- from income_statement()/balance_sheet() (both inner-join to
-- account_categories). The group's own rolled-up balance, shown via
-- chart_of_accounts_balances() (20250911003700, the previous feature this
-- session), achieves exactly the "control total" the source file's notes
-- describe — same end result, this system's actual mechanism.
-- ============================================================================

create or replace function app.seed_default_chart_of_accounts(p_org uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare r record;
begin
  insert into account_categories (org_id, code, name_ar, statement, section, normal_balance, sort_order) values
    (p_org, 'CASH',      'النقد وما يعادله',                         'balance_sheet',   'asset',     'debit',  10),
    (p_org, 'CHQR',       'شيكات وأوراق قبض',                        'balance_sheet',   'asset',     'debit',  20),
    (p_org, 'ARCUST',     'الذمم المدينة (عملاء ونزلاء وتطبيقات)',    'balance_sheet',   'asset',     'debit',  30),
    (p_org, 'AREMP',      'ذمم الموظفين',                            'balance_sheet',   'asset',     'debit',  40),
    (p_org, 'INV',        'المخزون',                                 'balance_sheet',   'asset',     'debit',  50),
    (p_org, 'TAXR',       'الضرائب القابلة للاسترداد',                'balance_sheet',   'asset',     'debit',  60),
    (p_org, 'PPD',        'سلف ومصروفات مدفوعة مقدمًا',               'balance_sheet',   'asset',     'debit',  70),
    (p_org, 'OCA',        'أصول متداولة وحسابات وسيطة أخرى',          'balance_sheet',   'asset',     'debit',  80),
    (p_org, 'PPE',        'الأصول الثابتة (بالتكلفة)',                'balance_sheet',   'asset',     'debit',  90),
    (p_org, 'ACCDEP',     'مجمع إهلاك الأصول الثابتة',                'balance_sheet',   'asset',     'debit', 100),
    (p_org, 'INTANG',     'الأصول غير الملموسة',                      'balance_sheet',   'asset',     'debit', 110),
    (p_org, 'LTDEP',      'تأمينات وأصول طويلة الأجل',                'balance_sheet',   'asset',     'debit', 120),
    (p_org, 'AP',         'الموردون',                                 'balance_sheet',   'liability', 'credit', 130),
    (p_org, 'APOTH',      'دائنون وحسابات دفع أخرى',                  'balance_sheet',   'liability', 'credit', 140),
    (p_org, 'CHQP',       'شيكات وأوراق دفع',                         'balance_sheet',   'liability', 'credit', 150),
    (p_org, 'TAXP',       'ضرائب ورسوم مستحقة',                       'balance_sheet',   'liability', 'credit', 160),
    (p_org, 'ACCR',       'مصروفات مستحقة',                           'balance_sheet',   'liability', 'credit', 170),
    (p_org, 'EMPLIAB',    'التزامات الموظفين',                        'balance_sheet',   'liability', 'credit', 180),
    (p_org, 'CUSTADV',    'دفعات العملاء المقدمة',                    'balance_sheet',   'liability', 'credit', 190),
    (p_org, 'STFIN',      'تمويلات قصيرة الأجل',                      'balance_sheet',   'liability', 'credit', 200),
    (p_org, 'OCL',        'التزامات متداولة أخرى',                    'balance_sheet',   'liability', 'credit', 210),
    (p_org, 'LTL',        'الالتزامات غير المتداولة',                 'balance_sheet',   'liability', 'credit', 220),
    (p_org, 'CAP',        'رأس المال',                                'balance_sheet',   'equity',    'credit', 230),
    (p_org, 'CURACC',     'الحسابات الجارية للملاك والشركاء',         'balance_sheet',   'equity',    'credit', 240),
    (p_org, 'RE',         'الأرباح والخسائر المتراكمة',               'balance_sheet',   'equity',    'credit', 250),
    (p_org, 'CYRESULT',   'نتيجة السنة الحالية',                      'balance_sheet',   'equity',    'credit', 260),
    (p_org, 'DRAW',       'المسحوبات والتوزيعات',                     'balance_sheet',   'equity',    'credit', 270),
    (p_org, 'RESV',       'الاحتياطيات',                              'balance_sheet',   'equity',    'credit', 280),
    (p_org, 'COGS',       'تكلفة المبيعات والخدمات',                  'income_statement','expense',   'debit', 290),
    (p_org, 'INVVAR',     'فروقات وهالك المخزون',                     'income_statement','expense',   'debit', 300),
    (p_org, 'STAFFCOST',  'تكاليف الموظفين',                          'income_statement','expense',   'debit', 310),
    (p_org, 'OCCUP',      'مصروفات الإشغال والطاقة والخدمات',         'income_statement','expense',   'debit', 320),
    (p_org, 'MAINT',      'مصروفات الصيانة والإصلاح',                 'income_statement','expense',   'debit', 330),
    (p_org, 'MKTG',       'مصروفات البيع والتسويق',                   'income_statement','expense',   'debit', 340),
    (p_org, 'ADMIN',      'المصروفات الإدارية والعمومية',             'income_statement','expense',   'debit', 350),
    (p_org, 'DEPR',       'مصروف الإهلاك والإطفاء',                   'income_statement','expense',   'debit', 360),
    (p_org, 'VEHIC',      'مصروفات المركبات والتوصيل',                'income_statement','expense',   'debit', 370),
    (p_org, 'OTHEXP',     'خسائر ومصروفات تشغيلية أخرى',              'income_statement','expense',   'debit', 380),
    (p_org, 'FIN',        'تكاليف التمويل',                           'income_statement','expense',   'debit', 390),
    (p_org, 'INCTAX',     'ضرائب على الدخل',                          'income_statement','expense',   'debit', 400),
    (p_org, 'REST_REV',   'مبيعات المطعم حسب المنتج',                 'income_statement','income',    'credit', 410),
    (p_org, 'REST_SVC',   'إيرادات خدمات المطعم',                     'income_statement','income',    'credit', 420),
    (p_org, 'HOTEL_REV',  'إيرادات الفندق',                           'income_statement','income',    'credit', 430),
    (p_org, 'OTH_OP_REV', 'إيرادات تشغيلية أخرى',                     'income_statement','income',    'credit', 440),
    (p_org, 'CONTRA_REV', 'حسابات مقابلة للإيراد',                    'income_statement','income',    'credit', 450),
    (p_org, 'OTH_INC',    'إيرادات ومكاسب أخرى',                      'income_statement','income',    'credit', 460)
  on conflict (org_id, code) do nothing;

  for r in select * from (values
    ('10000', null, 'الأصول', 'debit', false, null, false, null),
    ('11000', '10000', 'الأصول المتداولة', 'debit', false, null, false, null),
    ('11100', '11000', 'الصناديق والنقدية', 'debit', false, null, false, null),
    ('11101', '11100', 'صندوق المبيعات - شيكل', 'debit', true, 'CASH', false, null),
    ('11102', '11100', 'صندوق المصروفات اليومية - شيكل', 'debit', true, 'CASH', false, null),
    ('11103', '11100', 'الصندوق العام - شيكل', 'debit', true, 'CASH', false, null),
    ('11104', '11100', 'الصندوق العام - دولار', 'debit', true, 'CASH', false, null),
    ('11105', '11100', 'الصندوق العام - دينار', 'debit', true, 'CASH', false, null),
    ('11106', '11100', 'العهدة النقدية المستديمة', 'debit', true, 'CASH', false, null),
    ('11200', '11000', 'البنوك', 'debit', false, null, false, null),
    ('11201', '11200', 'بنك فلسطين - شيكل', 'debit', true, 'CASH', false, null),
    ('11202', '11200', 'بنك فلسطين - دولار', 'debit', true, 'CASH', false, null),
    ('11203', '11200', 'بنك القدس - شيكل', 'debit', true, 'CASH', false, null),
    ('11204', '11200', 'بنك القدس - دولار', 'debit', true, 'CASH', false, null),
    ('11300', '11000', 'المحافظ الإلكترونية ونقاط البيع', 'debit', false, null, false, null),
    ('11301', '11300', 'PalPay - علي', 'debit', true, 'CASH', false, null),
    ('11302', '11300', 'PalPay - فاطن', 'debit', true, 'CASH', false, null),
    ('11303', '11300', 'Jawwal Pay - علي', 'debit', true, 'CASH', false, null),
    ('11304', '11300', 'متحصلات بطاقات ونقاط بيع قيد التسوية', 'debit', true, 'CASH', false, null),
    ('11400', '11000', 'شيكات وأوراق قبض', 'debit', false, null, false, null),
    ('11401', '11400', 'شيكات تحت التحصيل - شيكل', 'debit', true, 'CHQR', false, null),
    ('11402', '11400', 'شيكات تحت التحصيل - دولار', 'debit', true, 'CHQR', false, null),
    ('11403', '11400', 'شيكات مرتجعة قيد المتابعة', 'debit', true, 'CHQR', false, null),
    ('11500', '11000', 'الذمم المدينة', 'debit', false, null, false, null),
    ('11501', '11500', 'ذمم العملاء - حساب مراقبة', 'debit', false, 'ARCUST', true, 'customers'),
    ('11502', '11500', 'ذمم نزلاء الفندق - حساب مراقبة', 'debit', false, 'ARCUST', true, 'customers'),
    ('11503', '11500', 'ذمم تطبيقات وشركات التوصيل', 'debit', true, 'ARCUST', false, null),
    ('11504', '11500', 'ذمم الموظفين', 'debit', false, 'AREMP', true, 'employees'),
    ('11505', '11500', 'مخصص الديون المشكوك في تحصيلها', 'credit', true, 'ARCUST', false, null),
    ('11600', '11000', 'المخزون', 'debit', false, null, false, null),
    ('11601', '11600', 'مخزون مواد خام البوظة', 'debit', true, 'INV', false, null),
    ('11602', '11600', 'مخزون مواد خام السلاش والعصائر', 'debit', true, 'INV', false, null),
    ('11603', '11600', 'مخزون مواد الطعام والمطبخ', 'debit', true, 'INV', false, null),
    ('11604', '11600', 'مخزون المشروبات الجاهزة', 'debit', true, 'INV', false, null),
    ('11605', '11600', 'مخزون العبوات والأكواب ومواد التغليف', 'debit', true, 'INV', false, null),
    ('11606', '11600', 'مخزون إنتاج نصف مصنع وجاهز', 'debit', true, 'INV', false, null),
    ('11607', '11600', 'مخزون مستلزمات الفندق والغرف', 'debit', true, 'INV', false, null),
    ('11608', '11600', 'مخزون قطع الغيار والصيانة', 'debit', true, 'INV', false, null),
    ('11609', '11600', 'بضاعة بالطريق', 'debit', true, 'INV', false, null),
    ('11700', '11000', 'الضرائب القابلة للاسترداد', 'debit', false, null, false, null),
    ('11701', '11700', 'ضريبة قيمة مضافة - مدخلات', 'debit', true, 'TAXR', false, null),
    ('11702', '11700', 'دفعات ضريبة دخل مقدمة', 'debit', true, 'TAXR', false, null),
    ('11703', '11700', 'ضريبة مخصومة من المنبع لنا', 'debit', true, 'TAXR', false, null),
    ('11800', '11000', 'السلف والمصروفات المدفوعة مقدمًا', 'debit', false, null, false, null),
    ('11801', '11800', 'سلف الموظفين', 'debit', true, 'PPD', false, null),
    ('11802', '11800', 'دفعات مقدمة للموردين', 'debit', true, 'PPD', false, null),
    ('11803', '11800', 'إيجار مدفوع مقدمًا', 'debit', true, 'PPD', false, null),
    ('11804', '11800', 'تأمين مدفوع مقدمًا', 'debit', true, 'PPD', false, null),
    ('11805', '11800', 'اشتراكات وبرامج مدفوعة مقدمًا', 'debit', true, 'PPD', false, null),
    ('11806', '11800', 'تأمينات مستردة قصيرة الأجل', 'debit', true, 'PPD', false, null),
    ('11900', '11000', 'أصول متداولة وحسابات وسيطة أخرى', 'debit', false, null, false, null),
    ('11901', '11900', 'تحويلات نقدية قيد التسوية', 'both', true, 'OCA', false, null),
    ('11902', '11900', 'مصاريف معلقة لحين التصنيف', 'debit', true, 'OCA', false, null),
    ('20000', null, 'الأصول غير المتداولة', 'debit', false, null, false, null),
    ('21000', '20000', 'الأصول الثابتة بالتكلفة', 'debit', false, null, false, null),
    ('21100', '21000', 'الأراضي والمباني والتحسينات', 'debit', false, null, false, null),
    ('21101', '21100', 'الأراضي', 'debit', true, 'PPE', false, null),
    ('21102', '21100', 'المباني', 'debit', true, 'PPE', false, null),
    ('21103', '21100', 'تحسينات وديكورات على عقار مستأجر', 'debit', true, 'PPE', false, null),
    ('21200', '21000', 'الأثاث والتجهيزات', 'debit', false, null, false, null),
    ('21201', '21200', 'أثاث المطعم والجلسات', 'debit', true, 'PPE', false, null),
    ('21202', '21200', 'أثاث المكاتب', 'debit', true, 'PPE', false, null),
    ('21203', '21200', 'أثاث وتجهيزات غرف الفندق', 'debit', true, 'PPE', false, null),
    ('21300', '21000', 'معدات المطعم والمطبخ', 'debit', false, null, false, null),
    ('21301', '21300', 'ماكينات تصنيع البوظة والباتش فريزر', 'debit', true, 'PPE', false, null),
    ('21302', '21300', 'ماكينات السوفت سيرف', 'debit', true, 'PPE', false, null),
    ('21303', '21300', 'الثلاجات والفريزرات', 'debit', true, 'PPE', false, null),
    ('21304', '21300', 'معدات وأدوات المطبخ', 'debit', true, 'PPE', false, null),
    ('21305', '21300', 'ماكينات القهوة والمشروبات', 'debit', true, 'PPE', false, null),
    ('21306', '21300', 'ماكينات ومعدات تصنيع الثلج', 'debit', true, 'PPE', false, null),
    ('21400', '21000', 'معدات الكهرباء والطاقة', 'debit', false, null, false, null),
    ('21401', '21400', 'المولدات الكهربائية', 'debit', true, 'PPE', false, null),
    ('21402', '21400', 'ألواح الطاقة الشمسية', 'debit', true, 'PPE', false, null),
    ('21403', '21400', 'الإنفرترات والبطاريات', 'debit', true, 'PPE', false, null),
    ('21404', '21400', 'تمديدات وتجهيزات كهربائية رأسمالية', 'debit', true, 'PPE', false, null),
    ('21500', '21000', 'المركبات ووسائل النقل', 'debit', false, null, false, null),
    ('21501', '21500', 'سيارة 1', 'debit', true, 'PPE', false, null),
    ('21502', '21500', 'دراجات ومركبات التوصيل', 'debit', true, 'PPE', false, null),
    ('21600', '21000', 'أجهزة الحاسوب والأنظمة والأمن', 'debit', false, null, false, null),
    ('21601', '21600', 'أجهزة الحاسوب والطابعات', 'debit', true, 'PPE', false, null),
    ('21602', '21600', 'أجهزة نقاط البيع والكاشير', 'debit', true, 'PPE', false, null),
    ('21603', '21600', 'كاميرات وأنظمة المراقبة', 'debit', true, 'PPE', false, null),
    ('21604', '21600', 'أجهزة الشبكات والاتصالات', 'debit', true, 'PPE', false, null),
    ('21700', '21000', 'معدات الفندق والخدمات', 'debit', false, null, false, null),
    ('21701', '21700', 'معدات المغسلة', 'debit', true, 'PPE', false, null),
    ('21702', '21700', 'مفروشات وبياضات طويلة الاستخدام', 'debit', true, 'PPE', false, null),
    ('21703', '21700', 'معدات النظافة والخدمات الفندقية', 'debit', true, 'PPE', false, null),
    ('21800', '21000', 'عدد وأدوات ومعدات أخرى', 'debit', false, null, false, null),
    ('21801', '21800', 'عدد وأدوات رأسمالية', 'debit', true, 'PPE', false, null),
    ('21802', '21800', 'معدات أخرى', 'debit', true, 'PPE', false, null),
    ('22000', '20000', 'مجمع إهلاك الأصول الثابتة', 'credit', false, null, false, null),
    ('22101', '22000', 'مجمع إهلاك المباني', 'credit', true, 'ACCDEP', false, null),
    ('22102', '22000', 'مجمع إهلاك التحسينات والديكورات', 'credit', true, 'ACCDEP', false, null),
    ('22201', '22000', 'مجمع إهلاك الأثاث والتجهيزات', 'credit', true, 'ACCDEP', false, null),
    ('22301', '22000', 'مجمع إهلاك معدات المطعم والمطبخ', 'credit', true, 'ACCDEP', false, null),
    ('22401', '22000', 'مجمع إهلاك معدات الكهرباء والطاقة', 'credit', true, 'ACCDEP', false, null),
    ('22501', '22000', 'مجمع إهلاك المركبات', 'credit', true, 'ACCDEP', false, null),
    ('22601', '22000', 'مجمع إهلاك الحاسوب والأنظمة والأمن', 'credit', true, 'ACCDEP', false, null),
    ('22701', '22000', 'مجمع إهلاك معدات الفندق والخدمات', 'credit', true, 'ACCDEP', false, null),
    ('22801', '22000', 'مجمع إهلاك المعدات الأخرى', 'credit', true, 'ACCDEP', false, null),
    ('23000', '20000', 'الأصول غير الملموسة', 'debit', false, null, false, null),
    ('23101', '23000', 'برامج وأنظمة محاسبية مملوكة', 'debit', true, 'INTANG', false, null),
    ('23102', '23000', 'تراخيص وحقوق استخدام طويلة الأجل', 'debit', true, 'INTANG', false, null),
    ('23901', '23000', 'مجمع إطفاء الأصول غير الملموسة', 'credit', true, 'INTANG', false, null),
    ('24000', '20000', 'تأمينات وأصول طويلة الأجل', 'debit', false, null, false, null),
    ('24101', '24000', 'تأمينات مستردة طويلة الأجل', 'debit', true, 'LTDEP', false, null),
    ('30000', null, 'الالتزامات', 'credit', false, null, false, null),
    ('31000', '30000', 'الالتزامات المتداولة', 'credit', false, null, false, null),
    ('31100', '31000', 'الموردون', 'credit', false, null, false, null),
    ('31101', '31100', 'الموردون المحليون - حساب مراقبة', 'credit', false, 'AP', true, 'suppliers'),
    ('31102', '31100', 'الموردون الخارجيون - حساب مراقبة', 'credit', false, 'AP', true, 'suppliers'),
    ('31200', '31000', 'دائنون وحسابات دفع أخرى', 'credit', false, null, false, null),
    ('31201', '31200', 'دائنون متنوعون', 'credit', true, 'APOTH', false, null),
    ('31202', '31200', 'مشتريات مستلمة غير مفوترة', 'credit', true, 'APOTH', false, null),
    ('31300', '31000', 'شيكات وأوراق دفع', 'credit', false, null, false, null),
    ('31301', '31300', 'شيكات تحت الدفع - شيكل', 'credit', true, 'CHQP', false, null),
    ('31302', '31300', 'شيكات تحت الدفع - دولار', 'credit', true, 'CHQP', false, null),
    ('31400', '31000', 'ضرائب ورسوم مستحقة', 'credit', false, null, false, null),
    ('31401', '31400', 'ضريبة قيمة مضافة - مخرجات', 'credit', true, 'TAXP', false, null),
    ('31402', '31400', 'صافي ضريبة القيمة المضافة المستحقة', 'credit', true, 'TAXP', false, null),
    ('31403', '31400', 'ضريبة دخل مستحقة', 'credit', true, 'TAXP', false, null),
    ('31404', '31400', 'ضرائب مقتطعة من الغير مستحقة للجهة الضريبية', 'credit', true, 'TAXP', false, null),
    ('31500', '31000', 'مصروفات مستحقة', 'credit', false, null, false, null),
    ('31501', '31500', 'رواتب وأجور مستحقة', 'credit', true, 'ACCR', false, null),
    ('31502', '31500', 'إيجارات مستحقة', 'credit', true, 'ACCR', false, null),
    ('31503', '31500', 'كهرباء ومياه واتصالات مستحقة', 'credit', true, 'ACCR', false, null),
    ('31504', '31500', 'أتعاب مهنية مستحقة', 'credit', true, 'ACCR', false, null),
    ('31505', '31500', 'مصروفات مستحقة أخرى', 'credit', true, 'ACCR', false, null),
    ('31600', '31000', 'التزامات الموظفين', 'credit', false, null, false, null),
    ('31601', '31600', 'صافي رواتب مستحقة للموظفين', 'credit', true, 'EMPLIAB', false, null),
    ('31602', '31600', 'استقطاعات موظفين مستحقة', 'credit', true, 'EMPLIAB', false, null),
    ('31603', '31600', 'مخصص مكافأة نهاية الخدمة - متداول', 'credit', true, 'EMPLIAB', false, null),
    ('31700', '31000', 'دفعات العملاء المقدمة', 'credit', false, null, false, null),
    ('31701', '31700', 'دفعات مقدمة من عملاء المطعم والحفلات', 'credit', true, 'CUSTADV', false, null),
    ('31702', '31700', 'دفعات مقدمة وحجوزات فندقية', 'credit', true, 'CUSTADV', false, null),
    ('31800', '31000', 'تمويلات قصيرة الأجل', 'credit', false, null, false, null),
    ('31801', '31800', 'تسهيلات وسحب على المكشوف', 'credit', true, 'STFIN', false, null),
    ('31802', '31800', 'قروض قصيرة الأجل', 'credit', true, 'STFIN', false, null),
    ('31803', '31800', 'الجزء المتداول من القروض طويلة الأجل', 'credit', true, 'STFIN', false, null),
    ('31900', '31000', 'التزامات متداولة أخرى', 'credit', false, null, false, null),
    ('31901', '31900', 'بطاقات ائتمان مستحقة', 'credit', true, 'OCL', false, null),
    ('31902', '31900', 'تأمينات عملاء مستردة', 'credit', true, 'OCL', false, null),
    ('31903', '31900', 'مبالغ معلقة دائنة لحين التسوية', 'credit', true, 'OCL', false, null),
    ('32000', '30000', 'الالتزامات غير المتداولة', 'credit', false, null, false, null),
    ('32101', '32000', 'قروض طويلة الأجل', 'credit', true, 'LTL', false, null),
    ('32102', '32000', 'التزامات عقود الإيجار طويلة الأجل', 'credit', true, 'LTL', false, null),
    ('32103', '32000', 'مخصص مكافأة نهاية الخدمة - طويل الأجل', 'credit', true, 'LTL', false, null),
    ('40000', null, 'حقوق الملكية', 'credit', false, null, false, null),
    ('41000', '40000', 'رأس المال', 'credit', false, null, false, null),
    ('41001', '41000', 'رأس مال المالك - علي', 'credit', true, 'CAP', false, null),
    ('41002', '41000', 'رأس مال شريك آخر', 'credit', true, 'CAP', false, null),
    ('42000', '40000', 'الحسابات الجارية للملاك والشركاء', 'both', false, null, false, null),
    ('42001', '42000', 'جاري المالك - علي', 'both', true, 'CURACC', false, null),
    ('42002', '42000', 'جاري الشريك - فاطن', 'both', true, 'CURACC', false, null),
    ('43000', '40000', 'الأرباح والخسائر المتراكمة', 'credit', false, null, false, null),
    ('43001', '43000', 'أرباح وخسائر سنوات سابقة', 'credit', true, 'RE', false, null),
    ('44000', '40000', 'نتيجة السنة الحالية', 'credit', false, null, false, null),
    ('44001', '44000', 'صافي ربح أو خسارة السنة الحالية', 'both', true, 'CYRESULT', false, null),
    ('45000', '40000', 'المسحوبات والتوزيعات', 'debit', false, null, false, null),
    ('45001', '45000', 'مسحوبات المالك - علي', 'debit', true, 'DRAW', false, null),
    ('45002', '45000', 'مسحوبات الشريك - فاطن', 'debit', true, 'DRAW', false, null),
    ('46000', '40000', 'الاحتياطيات', 'credit', false, null, false, null),
    ('46001', '46000', 'احتياطي عام', 'credit', true, 'RESV', false, null),
    ('50000', null, 'التكاليف والمصروفات', 'debit', false, null, false, null),
    ('51000', '50000', 'تكلفة المبيعات والخدمات', 'debit', false, null, false, null),
    ('51100', '51000', 'تكلفة مبيعات المطعم', 'debit', false, null, false, null),
    ('51101', '51100', 'تكلفة مبيعات البوظة', 'debit', true, 'COGS', false, null),
    ('51102', '51100', 'تكلفة مبيعات السلاش والعصائر', 'debit', true, 'COGS', false, null),
    ('51103', '51100', 'تكلفة مبيعات الطعام', 'debit', true, 'COGS', false, null),
    ('51104', '51100', 'تكلفة مبيعات المشروبات الجاهزة', 'debit', true, 'COGS', false, null),
    ('51105', '51100', 'تكلفة العبوات والتغليف المستهلكة', 'debit', true, 'COGS', false, null),
    ('51200', '51000', 'تكلفة الخدمات الفندقية', 'debit', false, null, false, null),
    ('51201', '51200', 'تكلفة مستلزمات النزلاء والغرف', 'debit', true, 'COGS', false, null),
    ('51202', '51200', 'تكلفة الغسيل والبياضات المستهلكة', 'debit', true, 'COGS', false, null),
    ('51203', '51200', 'تكلفة الإفطار والضيافة الفندقية', 'debit', true, 'COGS', false, null),
    ('51300', '51000', 'فروقات وهالك المخزون', 'debit', false, null, false, null),
    ('51301', '51300', 'هالك وتالف مواد خام', 'debit', true, 'INVVAR', false, null),
    ('51302', '51300', 'عجز وفروقات جرد المخزون', 'debit', true, 'INVVAR', false, null),
    ('51303', '51300', 'زيادة مخزون مكتشفة بالجرد', 'credit', true, 'INVVAR', false, null),
    ('52000', '50000', 'تكاليف الموظفين', 'debit', false, null, false, null),
    ('52101', '52000', 'رواتب وأجور', 'debit', true, 'STAFFCOST', false, null),
    ('52102', '52000', 'عمل إضافي وحوافز', 'debit', true, 'STAFFCOST', false, null),
    ('52103', '52000', 'بدلات نقل ووجبات ومزايا موظفين', 'debit', true, 'STAFFCOST', false, null),
    ('52104', '52000', 'علاج وتأمين صحي للموظفين', 'debit', true, 'STAFFCOST', false, null),
    ('52105', '52000', 'مصروف مكافأة نهاية الخدمة', 'debit', true, 'STAFFCOST', false, null),
    ('52106', '52000', 'مساهمات ورسوم مرتبطة بالرواتب', 'debit', true, 'STAFFCOST', false, null),
    ('53000', '50000', 'مصروفات الإشغال والطاقة والخدمات', 'debit', false, null, false, null),
    ('53101', '53000', 'إيجار المطعم', 'debit', true, 'OCCUP', false, null),
    ('53102', '53000', 'إيجار الفندق', 'debit', true, 'OCCUP', false, null),
    ('53103', '53000', 'كهرباء الشبكة أو البلدية', 'debit', true, 'OCCUP', false, null),
    ('53104', '53000', 'وقود وزيوت المولد', 'debit', true, 'OCCUP', false, null),
    ('53105', '53000', 'كهرباء مشتراة أو شحن كهرباء', 'debit', true, 'OCCUP', false, null),
    ('53106', '53000', 'مصاريف المياه', 'debit', true, 'OCCUP', false, null),
    ('53107', '53000', 'غاز ووقود تشغيل المطبخ', 'debit', true, 'OCCUP', false, null),
    ('53108', '53000', 'مواد وخدمات النظافة', 'debit', true, 'OCCUP', false, null),
    ('53200', '53000', 'مصروفات الصيانة والإصلاح', 'debit', false, null, false, null),
    ('53201', '53200', 'صيانة المباني والديكورات', 'debit', true, 'MAINT', false, null),
    ('53202', '53200', 'صيانة معدات المطعم والمطبخ', 'debit', true, 'MAINT', false, null),
    ('53203', '53200', 'صيانة الثلاجات والأجهزة الكهربائية', 'debit', true, 'MAINT', false, null),
    ('53204', '53200', 'صيانة المولد', 'debit', true, 'MAINT', false, null),
    ('53205', '53200', 'صيانة منظومة الطاقة الشمسية', 'debit', true, 'MAINT', false, null),
    ('53206', '53200', 'صيانة الحاسوب ونقاط البيع والشبكات', 'debit', true, 'MAINT', false, null),
    ('53207', '53200', 'صيانة المركبات', 'debit', true, 'MAINT', false, null),
    ('53208', '53200', 'صيانة شبكة المياه والصرف الصحي', 'debit', true, 'MAINT', false, null),
    ('53209', '53200', 'صيانة وإصلاحات متنوعة', 'debit', true, 'MAINT', false, null),
    ('53300', '53000', 'مصروفات البيع والتسويق', 'debit', false, null, false, null),
    ('53301', '53300', 'إعلانات ممولة ووسائل تواصل اجتماعي', 'debit', true, 'MKTG', false, null),
    ('53302', '53300', 'إدارة وتصميم محتوى صفحات التواصل', 'debit', true, 'MKTG', false, null),
    ('53303', '53300', 'طباعة ودعاية ولوحات', 'debit', true, 'MKTG', false, null),
    ('53304', '53300', 'عروض ترويجية وعينات مجانية', 'debit', true, 'MKTG', false, null),
    ('53305', '53300', 'عمولات تطبيقات وشركات التوصيل', 'debit', true, 'MKTG', false, null),
    ('53306', '53300', 'برنامج الولاء وتعويضات العملاء', 'debit', true, 'MKTG', false, null),
    ('53400', '53000', 'المصروفات الإدارية والعمومية', 'debit', false, null, false, null),
    ('53401', '53400', 'هاتف واتصالات', 'debit', true, 'ADMIN', false, null),
    ('53402', '53400', 'إنترنت', 'debit', true, 'ADMIN', false, null),
    ('53403', '53400', 'اشتراكات وصيانة برامج وأنظمة', 'debit', true, 'ADMIN', false, null),
    ('53404', '53400', 'تراخيص وتصاريح واشتراكات', 'debit', true, 'ADMIN', false, null),
    ('53405', '53400', 'رسوم معاملات رسمية وبلدية', 'debit', true, 'ADMIN', false, null),
    ('53406', '53400', 'عمولات ومصاريف بنكية', 'debit', true, 'ADMIN', false, null),
    ('53407', '53400', 'أتعاب محاسبة وتدقيق ومراجعة', 'debit', true, 'ADMIN', false, null),
    ('53408', '53400', 'أتعاب قانونية واستشارات', 'debit', true, 'ADMIN', false, null),
    ('53409', '53400', 'قرطاسية ومطبوعات مكتبية', 'debit', true, 'ADMIN', false, null),
    ('53410', '53400', 'ضيافة ومصاريف اجتماعات', 'debit', true, 'ADMIN', false, null),
    ('53411', '53400', 'مواصلات وسفر ومهمات', 'debit', true, 'ADMIN', false, null),
    ('53412', '53400', 'أمن وحراسة', 'debit', true, 'ADMIN', false, null),
    ('53413', '53400', 'تأمين حريق وسرقة وممتلكات', 'debit', true, 'ADMIN', false, null),
    ('53414', '53400', 'تأمين المركبات', 'debit', true, 'ADMIN', false, null),
    ('53415', '53400', 'مصروفات متنوعة محدودة', 'debit', true, 'ADMIN', false, null),
    ('53500', '53000', 'مصروف الإهلاك والإطفاء', 'debit', false, null, false, null),
    ('53501', '53500', 'إهلاك المباني والتحسينات', 'debit', true, 'DEPR', false, null),
    ('53502', '53500', 'إهلاك الأثاث والتجهيزات', 'debit', true, 'DEPR', false, null),
    ('53503', '53500', 'إهلاك معدات المطعم والمطبخ', 'debit', true, 'DEPR', false, null),
    ('53504', '53500', 'إهلاك معدات الكهرباء والطاقة', 'debit', true, 'DEPR', false, null),
    ('53505', '53500', 'إهلاك المركبات', 'debit', true, 'DEPR', false, null),
    ('53506', '53500', 'إهلاك الحاسوب والأنظمة والأمن', 'debit', true, 'DEPR', false, null),
    ('53507', '53500', 'إهلاك معدات الفندق والخدمات', 'debit', true, 'DEPR', false, null),
    ('53508', '53500', 'إطفاء البرامج والأصول غير الملموسة', 'debit', true, 'DEPR', false, null),
    ('53600', '53000', 'مصروفات المركبات والتوصيل', 'debit', false, null, false, null),
    ('53601', '53600', 'وقود وزيوت المركبات', 'debit', true, 'VEHIC', false, null),
    ('53602', '53600', 'ترخيص وتأمين المركبات', 'debit', true, 'VEHIC', false, null),
    ('53603', '53600', 'مصاريف توصيل ونقل خارجي', 'debit', true, 'VEHIC', false, null),
    ('53700', '53000', 'خسائر ومصروفات تشغيلية أخرى', 'debit', false, null, false, null),
    ('53701', '53700', 'عجز الصندوق والنقدية', 'debit', true, 'OTHEXP', false, null),
    ('53702', '53700', 'ديون معدومة ومشكوك فيها', 'debit', true, 'OTHEXP', false, null),
    ('53703', '53700', 'خسائر تلف أصول وممتلكات', 'debit', true, 'OTHEXP', false, null),
    ('53704', '53700', 'غرامات ومخالفات غير ضريبية', 'debit', true, 'OTHEXP', false, null),
    ('53705', '53700', 'تبرعات ومساعدات', 'debit', true, 'OTHEXP', false, null),
    ('53706', '53700', 'خسائر فروق عملة', 'debit', true, 'OTHEXP', false, null),
    ('53800', '53000', 'تكاليف التمويل', 'debit', false, null, false, null),
    ('53801', '53800', 'فوائد وعمولات القروض', 'debit', true, 'FIN', false, null),
    ('53802', '53800', 'تكلفة تمويل وعقود إيجار', 'debit', true, 'FIN', false, null),
    ('53900', '53000', 'ضرائب على الدخل', 'debit', false, null, false, null),
    ('53901', '53900', 'مصروف ضريبة الدخل', 'debit', true, 'INCTAX', false, null),
    ('60000', null, 'الإيرادات', 'credit', false, null, false, null),
    ('61000', '60000', 'إيرادات المطعم', 'credit', false, null, false, null),
    ('61100', '61000', 'مبيعات المطعم حسب المنتج', 'credit', false, null, false, null),
    ('61101', '61100', 'مبيعات البوظة', 'credit', true, 'REST_REV', false, null),
    ('61102', '61100', 'مبيعات السلاش والعصائر', 'credit', true, 'REST_REV', false, null),
    ('61103', '61100', 'مبيعات المشروبات الباردة الجاهزة', 'credit', true, 'REST_REV', false, null),
    ('61104', '61100', 'مبيعات القهوة والمشروبات الساخنة', 'credit', true, 'REST_REV', false, null),
    ('61105', '61100', 'مبيعات الطعام والوجبات', 'credit', true, 'REST_REV', false, null),
    ('61106', '61100', 'مبيعات الحلويات', 'credit', true, 'REST_REV', false, null),
    ('61107', '61100', 'مبيعات المياه', 'credit', true, 'REST_REV', false, null),
    ('61200', '61000', 'إيرادات خدمات المطعم', 'credit', false, null, false, null),
    ('61201', '61200', 'رسوم خدمة وتوصيل محصلة من العملاء', 'credit', true, 'REST_SVC', false, null),
    ('61202', '61200', 'إيرادات حفلات وحجوزات', 'credit', true, 'REST_SVC', false, null),
    ('62000', '60000', 'إيرادات الفندق', 'credit', false, null, false, null),
    ('62101', '62000', 'إيرادات الغرف والإقامة', 'credit', true, 'HOTEL_REV', false, null),
    ('62102', '62000', 'إيرادات خدمات الغسيل', 'credit', true, 'HOTEL_REV', false, null),
    ('62103', '62000', 'إيرادات الطعام والضيافة الفندقية', 'credit', true, 'HOTEL_REV', false, null),
    ('62104', '62000', 'رسوم إلغاء أو تعديل الحجوزات', 'credit', true, 'HOTEL_REV', false, null),
    ('62105', '62000', 'إيرادات خدمات فندقية أخرى', 'credit', true, 'HOTEL_REV', false, null),
    ('63000', '60000', 'إيرادات تشغيلية أخرى', 'credit', false, null, false, null),
    ('63101', '63000', 'إيراد تأجير معدات أو مساحات', 'credit', true, 'OTH_OP_REV', false, null),
    ('63102', '63000', 'إيراد بيع مخلفات ومواد مستعملة', 'credit', true, 'OTH_OP_REV', false, null),
    ('64000', '60000', 'حسابات مقابلة للإيراد', 'debit', false, null, false, null),
    ('64101', '64000', 'خصم مسموح به للعملاء', 'debit', true, 'CONTRA_REV', false, null),
    ('64102', '64000', 'مردودات ومسموحات المبيعات', 'debit', true, 'CONTRA_REV', false, null),
    ('64103', '64000', 'تعويضات عملاء مخفضة للإيراد', 'debit', true, 'CONTRA_REV', false, null),
    ('65000', '60000', 'إيرادات ومكاسب أخرى', 'credit', false, null, false, null),
    ('65101', '65000', 'خصم مكتسب من الموردين', 'credit', true, 'OTH_INC', false, null),
    ('65102', '65000', 'أرباح فروق عملة', 'credit', true, 'OTH_INC', false, null),
    ('65103', '65000', 'أرباح بيع أصول ثابتة', 'credit', true, 'OTH_INC', false, null),
    ('65104', '65000', 'زيادة الصندوق والنقدية', 'credit', true, 'OTH_INC', false, null),
    ('65105', '65000', 'إيرادات أخرى غير تشغيلية', 'credit', true, 'OTH_INC', false, null)
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
-- create_organization() — same as the true latest body (20250911003500),
-- plus one new call so every future org starts with a real chart of
-- accounts instead of zero.
-- ---------------------------------------------------------------------------
create or replace function create_organization(
  p_code text,
  p_name_ar text,
  p_base_currency_code text default 'NIS',
  p_base_currency_name_ar text default 'شيكل',
  p_fiscal_year_start_month int default 1
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

  insert into organizations (code, name_ar, fiscal_year_start_month)
  values (p_code, p_name_ar, p_fiscal_year_start_month)
  returning id into v_org;

  insert into currencies (org_id, code, name_ar, is_base, decimal_places)
  values (v_org, p_base_currency_code, p_base_currency_name_ar, true, 2)
  returning id into v_cur;

  update organizations set base_currency_id = v_cur where id = v_org;

  insert into org_settings (org_id, key, value) values (v_org, 'tax', jsonb_build_object('enabled', true, 'rate', 0.16));

  perform app.seed_default_chart_of_accounts(v_org);

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
