const money = new Intl.NumberFormat('ar-EG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const int = new Intl.NumberFormat('ar-EG');

export const fmtMoney = (n: number | null | undefined) => money.format(Number(n ?? 0));
export const fmtInt = (n: number | null | undefined) => int.format(Number(n ?? 0));
export const fmtDate = (d: string | null | undefined) =>
  d ? new Date(d).toLocaleDateString('ar-EG', { year: 'numeric', month: '2-digit', day: '2-digit' }) : '';

export const today = () => new Date().toISOString().slice(0, 10);

/**
 * PostgREST's .or()/.ilike() filter strings are built by hand-interpolating
 * the search term — `,` separates conditions and `.`/`(`/`)` are part of its
 * own grammar, so a search box that lets someone type those breaks the query
 * (or, worse, changes what it filters on) rather than just finding nothing.
 * Strip them before building any such filter string.
 */
export const sanitizeSearchTerm = (q: string) => q.trim().replace(/[,()."]/g, '');
