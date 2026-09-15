export interface AccOpt { id: string; code: string; name_ar: string; category_id: string | null; account_categories: { name_ar: string } | null; }

const UNCATEGORIZED = 'غير مصنّف';

// grouped <optgroup> account picker — dozens of real accounts flat is hard
// to scan, so group by account_categories the same way the chart of
// accounts itself is organized.
export function AccountSelect({ value, onChange, placeholder, accounts }: {
  value: string; onChange: (v: string) => void; placeholder: string; accounts: AccOpt[] | undefined;
}) {
  const order: string[] = [];
  const groups = new Map<string, { label: string; rows: AccOpt[] }>();
  for (const a of accounts ?? []) {
    const key = a.category_id ?? 'none';
    const label = a.account_categories?.name_ar ?? UNCATEGORIZED;
    if (!groups.has(key)) { groups.set(key, { label, rows: [] }); order.push(key); }
    groups.get(key)!.rows.push(a);
  }
  return (
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">{placeholder}</option>
      {order.map((key) => (
        <optgroup key={key} label={groups.get(key)!.label}>
          {groups.get(key)!.rows.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
        </optgroup>
      ))}
    </select>
  );
}
