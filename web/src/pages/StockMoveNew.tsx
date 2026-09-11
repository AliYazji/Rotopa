import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { sanitizeSearchTerm, today } from '../lib/format.ts';

interface WhOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }
interface ItemHit { id: string; code: string; name_ar: string; base_unit_name: string; }

interface Line { key: number; itemId: string; itemLabel: string; qty: string; unitCost: string }
let keySeq = 0;
const emptyLine = (): Line => ({ key: keySeq++, itemId: '', itemLabel: '', qty: '', unitCost: '' });

const TITLE: Record<string, string> = {
  opening: 'رصيد افتتاحي للمخزون', adjustment_in: 'إضافة للمخزون',
  adjustment_out: 'صرف من المخزون', transfer: 'تحويل بين مستودعين',
};
const NEEDS_COST: Record<string, boolean> = { opening: true, adjustment_in: true, adjustment_out: false, transfer: false };

function ItemPicker({ line, onPick }: { line: Line; onPick: (id: string, label: string) => void }) {
  const [q, setQ] = useState(line.itemLabel);
  const [open, setOpen] = useState(false);
  const { data } = useQuery({
    queryKey: ['item-search', q],
    enabled: open && q.trim().length >= 2,
    queryFn: async (): Promise<ItemHit[]> => {
      const term = sanitizeSearchTerm(q);
      const { data, error } = await supabase.from('items')
        .select('id, code, name_ar, base_unit_name')
        .or(`name_ar.ilike.%${term}%,code.ilike.%${term}%`)
        .eq('is_stock_tracked', true).limit(8);
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
        <div className="card" style={{ position: 'absolute', zIndex: 10, top: '100%', insetInlineStart: 0, width: 260, padding: '0.25rem', maxHeight: 220, overflowY: 'auto' }}>
          {data.map((it) => (
            <div
              key={it.id}
              style={{ padding: '0.4rem 0.5rem', cursor: 'pointer', borderRadius: 6 }}
              onMouseDown={() => { onPick(it.id, `${it.code} · ${it.name_ar}`); setQ(`${it.code} · ${it.name_ar}`); setOpen(false); }}
            >
              <span className="mono">{it.code}</span> · {it.name_ar} <span className="muted">({it.base_unit_name})</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default function StockMoveNew() {
  const { org } = useOrg();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const type = (['opening', 'adjustment_in', 'adjustment_out', 'transfer'].includes(params.get('type') ?? '')
    ? params.get('type')
    : 'adjustment_in') as string;

  const [date, setDate] = useState(today());
  const [desc, setDesc] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [fromWarehouseId, setFromWarehouseId] = useState('');
  const [toWarehouseId, setToWarehouseId] = useState('');
  const [postToGl, setPostToGl] = useState(type !== 'transfer');
  const [contraAccountId, setContraAccountId] = useState('');
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error;
      return data as WhOpt[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id],
    enabled: !!org && type !== 'transfer',
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar').eq('is_postable', true).order('code');
      if (error) throw error;
      return data as AccOpt[];
    },
  });

  function setLine(key: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function save() {
    setErr(null);
    setBusy(true);
    try {
      const validLines = lines.filter((l) => l.itemId && (parseFloat(l.qty) || 0) > 0);
      if (validLines.length === 0) throw new Error('أضف سطراً واحداً على الأقل بكمية صحيحة');
      if (type === 'transfer' && (!fromWarehouseId || !toWarehouseId)) throw new Error('اختر مستودع المصدر والوجهة');
      if (type !== 'transfer' && !warehouseId) throw new Error('اختر المستودع');
      if (NEEDS_COST[type] && validLines.some((l) => !(parseFloat(l.unitCost) >= 0))) throw new Error('كل سطر يحتاج تكلفة');

      let payload: any[];
      if (type === 'transfer') {
        payload = validLines.flatMap((l) => [
          { item_id: l.itemId, warehouse_id: fromWarehouseId, direction: 'out', entered_qty: parseFloat(l.qty) },
          { item_id: l.itemId, warehouse_id: toWarehouseId, direction: 'in', entered_qty: parseFloat(l.qty), unit_cost: 0 },
        ]);
      } else {
        payload = validLines.map((l) => ({
          item_id: l.itemId, warehouse_id: warehouseId,
          direction: type === 'adjustment_out' ? 'out' : 'in',
          entered_qty: parseFloat(l.qty),
          unit_cost: NEEDS_COST[type] ? parseFloat(l.unitCost) : undefined,
        }));
      }

      const { data: moveId, error } = await supabase.rpc('create_stock_move', {
        p_org: org!.id, p_move_type: type, p_move_date: date, p_description: desc, p_lines: payload,
      });
      if (error) throw error;

      const { error: pErr } = await supabase.rpc('post_stock_move', {
        p_move_id: moveId,
        p_contra_account_id: type !== 'transfer' && postToGl ? contraAccountId || null : null,
      });
      if (pErr) throw pErr;
      nav('/stock-moves');
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>{TITLE[type] ?? 'حركة مخزون'}</h1>
      <div className="card">
        <div className="row">
          <div className="field" style={{ width: 180 }}>
            <label>التاريخ</label>
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          {type === 'transfer' ? (
            <>
              <div className="field grow">
                <label>من مستودع</label>
                <select value={fromWarehouseId} onChange={(e) => setFromWarehouseId(e.target.value)}>
                  <option value="">—</option>
                  {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
                </select>
              </div>
              <div className="field grow">
                <label>إلى مستودع</label>
                <select value={toWarehouseId} onChange={(e) => setToWarehouseId(e.target.value)}>
                  <option value="">—</option>
                  {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
                </select>
              </div>
            </>
          ) : (
            <div className="field grow">
              <label>المستودع</label>
              <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
                <option value="">—</option>
                {warehouses?.map((w) => <option key={w.id} value={w.id}>{w.code} · {w.name_ar}</option>)}
              </select>
            </div>
          )}
        </div>
        <div className="field">
          <label>البيان</label>
          <input value={desc} onChange={(e) => setDesc(e.target.value)} />
        </div>

        <table style={{ marginTop: '0.5rem' }}>
          <thead>
            <tr>
              <th>الصنف</th>
              <th style={{ width: 110 }} className="num">الكمية</th>
              {NEEDS_COST[type] && <th style={{ width: 110 }} className="num">تكلفة الوحدة</th>}
              <th style={{ width: 40 }} />
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.key}>
                <td><ItemPicker line={l} onPick={(id, label) => setLine(l.key, { itemId: id, itemLabel: label })} /></td>
                <td><input className="num" inputMode="decimal" value={l.qty} onChange={(e) => setLine(l.key, { qty: e.target.value })} /></td>
                {NEEDS_COST[type] && <td><input className="num" inputMode="decimal" value={l.unitCost} onChange={(e) => setLine(l.key, { unitCost: e.target.value })} /></td>}
                <td>{lines.length > 1 && <button type="button" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <button type="button" onClick={() => setLines((ls) => [...ls, emptyLine()])} style={{ marginTop: '0.5rem' }}>+ سطر</button>

        {type !== 'transfer' && (
          <div className="row" style={{ marginTop: '1rem', alignItems: 'center' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', width: 'auto', margin: 0 }}>
              <input type="checkbox" style={{ width: 'auto' }} checked={postToGl} onChange={(e) => setPostToGl(e.target.checked)} />
              ترحيل قيد محاسبي تلقائي
            </label>
            {postToGl && (
              <select value={contraAccountId} onChange={(e) => setContraAccountId(e.target.value)} style={{ width: 240 }}>
                <option value="">الحساب المقابل…</option>
                {accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name_ar}</option>)}
              </select>
            )}
          </div>
        )}

        {err && <p className="error">{err}</p>}
        <button className="btn-primary" disabled={busy} onClick={save} style={{ marginTop: '1rem' }}>حفظ وترحيل</button>
      </div>
    </>
  );
}
