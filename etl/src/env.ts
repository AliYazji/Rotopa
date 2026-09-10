import 'dotenv/config';

function req(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name} (copy etl/.env.example to etl/.env)`);
  return v;
}

export const env = {
  mssql: {
    server: process.env.MSSQL_HOST ?? 'localhost',
    port: Number(process.env.MSSQL_PORT ?? 1433),
    user: req('MSSQL_USER'),
    password: req('MSSQL_PASSWORD'),
    database: req('MSSQL_DATABASE'),
    options: {
      encrypt: (process.env.MSSQL_ENCRYPT ?? 'false') === 'true',
      trustServerCertificate: true,
    },
  },
  targetUrl: req('TARGET_DATABASE_URL'),
  org: {
    code: process.env.ORG_CODE ?? 'RETAJ',
    nameAr: process.env.ORG_NAME_AR ?? 'مؤسسة',
    baseCurrencyLegacyNo: Number(process.env.BASE_CURRENCY_LEGACY_NO ?? 1),
    fiscalYearStartMonth: Number(process.env.FISCAL_YEAR_START_MONTH ?? 1),
    adminUserId: process.env.ADMIN_USER_ID || null,
  },
};
