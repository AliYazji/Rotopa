import mssql from 'mssql';
import { env } from './env.ts';

let pool: mssql.ConnectionPool | null = null;

export async function legacy(): Promise<mssql.ConnectionPool> {
  if (!pool) pool = await new mssql.ConnectionPool(env.mssql).connect();
  return pool;
}

export async function q<T = any>(sql: string): Promise<T[]> {
  const p = await legacy();
  const r = await p.request().query(sql);
  return r.recordset as T[];
}

export async function closeLegacy(): Promise<void> {
  await pool?.close();
  pool = null;
}

// ── source row shapes ────────────────────────────────────────────────────────
export interface LegacyCurrency {
  FieldNo: number;
  ADescName: string | null;
  EDescName: string | null;
  Simbol: string | null;
  curr_str1: string | null;
  curr_str2: string | null;
}

export interface LegacyAccount {
  acc_no: string;
  arabic_name: string | null;
  acc_name: string | null;
  father_acc: string | null;
  acc_lavel: number | null;
  account_nature: number | null;
  currncey: number | null;
  accountCategoryType: number | null;
  CashFlowClass: number | null;
  StopTransaction: number | null;
  del: number;
}

export interface LegacyCategory {
  CategoryTypeNo: number;
  CategoryTypeName: string | null;
  CategoryTypeNameEng: string | null;
  CategoryTypGroup: number | null;
  CategoryTypeSort: number | null;
}

export interface LegacyDealer {
  Dealer_no: number;
  Dealer_type: number;
  Dealer_name: string | null;
  arabic_name: string | null;
  acc_no: string;
  currncey: number | null;
  address: string | null;
  city: string | null;
  tel_no: string | null;
  email: string | null;
  reg_no: string | null;
  max_credit_balance: number | null;
  sales_discount: number | null;
  purchase_discount: number | null;
}
