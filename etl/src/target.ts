import pg from 'pg';
import { env } from './env.ts';

// numeric -> JS number (safe for our magnitudes; the ledger itself keeps
// numeric(19,4) precision server-side).
pg.types.setTypeParser(1700, (v) => (v === null ? null : Number(v)));

export const pool = new pg.Pool({ connectionString: env.targetUrl, max: 4 });

export async function one<T = any>(sql: string, params: any[] = []): Promise<T> {
  const r = await pool.query(sql, params);
  return r.rows[0] as T;
}
export async function all<T = any>(sql: string, params: any[] = []): Promise<T[]> {
  const r = await pool.query(sql, params);
  return r.rows as T[];
}
export async function exec(sql: string, params: any[] = []): Promise<number> {
  const r = await pool.query(sql, params);
  return r.rowCount ?? 0;
}

export async function tx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('begin');
    const out = await fn(c);
    await c.query('commit');
    return out;
  } catch (e) {
    await c.query('rollback');
    throw e;
  } finally {
    c.release();
  }
}

/**
 * Idempotently provision the target organization, its base currency, the three
 * system roles, and the current fiscal year. Runs as a direct superuser
 * connection, so it does not go through create_organization()'s auth check.
 * Returns { orgId, baseCurrencyId }.
 */
export async function provisionOrg(): Promise<{ orgId: string; baseCurrencyId: string }> {
  return tx(async (c) => {
    const existing = await c.query(`select id, base_currency_id from organizations where code = $1`, [env.org.code]);
    if (existing.rows[0]?.base_currency_id) {
      return { orgId: existing.rows[0].id, baseCurrencyId: existing.rows[0].base_currency_id };
    }

    const org = existing.rows[0]?.id
      ? existing.rows[0].id
      : (await c.query(
          `insert into organizations (code, name_ar, fiscal_year_start_month) values ($1,$2,$3) returning id`,
          [env.org.code, env.org.nameAr, env.org.fiscalYearStartMonth],
        )).rows[0].id;

    const cur = (await c.query(
      `insert into currencies (org_id, code, name_ar, is_base, decimal_places)
       values ($1,'BASE','عملة الأساس',true,2)
       on conflict (org_id, code) do update set is_base = true
       returning id`,
      [org],
    )).rows[0].id;

    await c.query(`update organizations set base_currency_id = $1 where id = $2`, [cur, org]);

    // system roles + permissions
    for (const [code, name] of [['owner', 'مالك'], ['accountant', 'محاسب'], ['viewer', 'مطّلع']] as const) {
      await c.query(
        `insert into roles (org_id, code, name_ar, is_system) values ($1,$2,$3,true)
         on conflict (org_id, code) do nothing`,
        [org, code, name],
      );
    }
    await c.query(
      `insert into role_permissions (role_id, permission_key)
       select r.id, p.key from roles r cross join permissions p
       where r.org_id = $1 and r.code = 'owner'
       on conflict do nothing`,
      [org],
    );
    await c.query(
      `insert into role_permissions (role_id, permission_key)
       select r.id, p.key from roles r join permissions p
         on p.key not in ('org.manage','roles.write','members.write')
       where r.org_id = $1 and r.code = 'accountant'
       on conflict do nothing`,
      [org],
    );
    await c.query(
      `insert into role_permissions (role_id, permission_key)
       select r.id, k from roles r cross join (values ('audit.read'),('reports.view')) v(k)
       where r.org_id = $1 and r.code = 'viewer'
       on conflict do nothing`,
      [org],
    );

    if (env.org.adminUserId) {
      await c.query(
        `insert into memberships (org_id, user_id, role_id, is_owner)
         select $1, $2, r.id, true from roles r where r.org_id = $1 and r.code = 'owner'
         on conflict (org_id, user_id) do nothing`,
        [org, env.org.adminUserId],
      );
    }

    // current fiscal year + 12 periods
    const year = new Date().getFullYear();
    const fyExists = await c.query(`select 1 from fiscal_years where org_id = $1 and code = $2`, [org, String(year)]);
    if (!fyExists.rows[0]) {
      const start = new Date(Date.UTC(year, env.org.fiscalYearStartMonth - 1, 1));
      const fy = (await c.query(
        `insert into fiscal_years (org_id, code, start_date, end_date)
         values ($1,$2,$3,$4) returning id`,
        [org, String(year), iso(start), iso(new Date(Date.UTC(year + 1, env.org.fiscalYearStartMonth - 1, 0)))],
      )).rows[0].id;
      for (let i = 0; i < 12; i++) {
        const ps = new Date(Date.UTC(year, env.org.fiscalYearStartMonth - 1 + i, 1));
        const pe = new Date(Date.UTC(year, env.org.fiscalYearStartMonth + i, 0));
        await c.query(
          `insert into fiscal_periods (org_id, fiscal_year_id, period_no, start_date, end_date)
           values ($1,$2,$3,$4,$5)`,
          [org, fy, i + 1, iso(ps), iso(pe)],
        );
      }
    }

    return { orgId: org, baseCurrencyId: cur };
  });
}

export function iso(d: Date): string {
  return d.toISOString().slice(0, 10);
}
