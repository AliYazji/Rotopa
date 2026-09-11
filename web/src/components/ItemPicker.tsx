import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { fmtMoney, sanitizeSearchTerm } from '../lib/format.ts';

interface ItemHit {
  id: string; code: string; name_ar: string; base_unit_name: string; sales_price: number;
  onHand: number | null;   // null = stock unknown (no warehouse given)
}

/** Type-ahead search over the item catalog — never loads the whole table,
 * so it stays fast whether there are 50 items or 5,000. Used anywhere a
 * document needs to pick an item by name or code (stock moves, invoices).
 *
 * When `warehouseId` is given, shows each match's stock on hand *there* —
 * so a zero-stock item is visible as zero before anyone tries to sell it,
 * not discovered afterward as a rejected posting. */
export function ItemPicker({
  initialLabel = '',
  warehouseId,
  onPick,
}: {
  initialLabel?: string;
  warehouseId?: string;
  onPick: (item: ItemHit) => void;
}) {
  const [q, setQ] = useState(initialLabel);
  const [open, setOpen] = useState(false);
  const { data } = useQuery({
    queryKey: ['item-search', q, warehouseId],
    enabled: open && q.trim().length >= 2,
    queryFn: async (): Promise<ItemHit[]> => {
      const term = sanitizeSearchTerm(q);
      const { data, error } = await supabase
        .from('items')
        .select('id, code, name_ar, base_unit_name, sales_price, item_warehouse_balances(qty, warehouse_id)')
        .or(`name_ar.ilike.%${term}%,code.ilike.%${term}%`)
        .eq('is_stock_tracked', true)
        .eq('is_active', true)
        .limit(8);
      if (error) throw error;
      return (data as any[]).map((it) => ({
        id: it.id, code: it.code, name_ar: it.name_ar, base_unit_name: it.base_unit_name, sales_price: it.sales_price,
        onHand: warehouseId
          ? Number(it.item_warehouse_balances.find((b: any) => b.warehouse_id === warehouseId)?.qty ?? 0)
          : null,
      }));
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
        <div className="card" style={{ position: 'absolute', zIndex: 10, top: '100%', insetInlineStart: 0, width: 300, padding: '0.25rem', maxHeight: 240, overflowY: 'auto' }}>
          {data.map((it) => (
            <div
              key={it.id}
              className="row"
              style={{ padding: '0.4rem 0.5rem', cursor: 'pointer', borderRadius: 6, justifyContent: 'space-between', gap: '0.5rem' }}
              onMouseDown={() => { onPick(it); setQ(`${it.code} · ${it.name_ar}`); setOpen(false); }}
            >
              <span><span className="mono">{it.code}</span> · {it.name_ar} <span className="muted">({it.base_unit_name})</span></span>
              {it.onHand !== null && (
                <span className="mono" style={{ color: it.onHand > 0 ? 'var(--credit)' : 'var(--danger)', whiteSpace: 'nowrap' }}>
                  {it.onHand > 0 ? fmtMoney(it.onHand) : 'لا يوجد رصيد'}
                </span>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
