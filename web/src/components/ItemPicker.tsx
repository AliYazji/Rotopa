import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { sanitizeSearchTerm } from '../lib/format.ts';

interface ItemHit { id: string; code: string; name_ar: string; base_unit_name: string; sales_price: number }

/** Type-ahead search over the item catalog — never loads the whole table,
 * so it stays fast whether there are 50 items or 5,000. Used anywhere a
 * document needs to pick an item by name or code (stock moves, invoices). */
export function ItemPicker({
  initialLabel = '',
  onPick,
}: {
  initialLabel?: string;
  onPick: (item: ItemHit) => void;
}) {
  const [q, setQ] = useState(initialLabel);
  const [open, setOpen] = useState(false);
  const { data } = useQuery({
    queryKey: ['item-search', q],
    enabled: open && q.trim().length >= 2,
    queryFn: async (): Promise<ItemHit[]> => {
      const term = sanitizeSearchTerm(q);
      const { data, error } = await supabase
        .from('items')
        .select('id, code, name_ar, base_unit_name, sales_price')
        .or(`name_ar.ilike.%${term}%,code.ilike.%${term}%`)
        .eq('is_stock_tracked', true)
        .eq('is_active', true)
        .limit(8);
      if (error) throw error;
      return data as ItemHit[];
    },
  });
  return (
    <div style={{ position: 'relative' }}>
      <input
        value={q}
        placeholder="اكتب اسم الصنف أو رمزه…"
        onChange={(e) => { setQ(e.target.value); setOpen(true); }}
        onFocus={() => setOpen(true)}
      />
      {open && data && data.length > 0 && (
        <div className="card" style={{ position: 'absolute', zIndex: 10, top: '100%', insetInlineStart: 0, width: 280, padding: '0.25rem', maxHeight: 220, overflowY: 'auto' }}>
          {data.map((it) => (
            <div
              key={it.id}
              style={{ padding: '0.4rem 0.5rem', cursor: 'pointer', borderRadius: 6 }}
              onMouseDown={() => { onPick(it); setQ(`${it.code} · ${it.name_ar}`); setOpen(false); }}
            >
              <span className="mono">{it.code}</span> · {it.name_ar} <span className="muted">({it.base_unit_name})</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
