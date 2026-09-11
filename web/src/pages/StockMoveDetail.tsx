import { useEffect, useMemo, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, fmtMoney, today, translateError } from '../lib/format.ts';
import { ItemPicker } from '../components/ItemPicker.tsx';

interface Move {
  id: string; move_no: number; move_date: string; move_type: string;
  status: 'draft' | 'posted' | 'void'; description: string; void_reason: string | null;
}
interface Line {
  id: string; line_no: number; item_id: string; warehouse_id: string; direction: 'in' | 'out';
  entered_qty: number; unit_cost: number | null;
  item: { code: string; name_ar: string } | null; warehouse: { code: string; name_ar: string } | null;
}
interface WhOpt { id: string; code: string; name_ar: string; }
interface AccOpt { id: string; code: string; name_ar: string; }
interface EditLine { key: number; itemId: string; itemLabel: string; qty: string; unitCost: string; onHand: number | null }
let keySeq = 0;

const TITLE: Record<string, string> = {
  opening: 'رصيد افتتاحي للمخزون', adjustment_in: 'إضافة للمخزون',
  adjustment_out: 'صرف من المخزون', transfer: 'تحويل بين مستودعين',
  purchase_in: 'وارد شراء', sale_out: 'صادر بيع',
};
const NEEDS_COST: Record<string, boolean> = { opening: true, adjustment_in: true, adjustment_out: false, transfer: false };
const STATUS: Record<string, string> = { draft: 'مسودة', posted: 'مرحّلة', void: 'ملغاة' };

export default function StockMoveDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const { org } = useOrg();
  const qc = useQueryClient();
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);
  const [desc, setDesc] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [fromWarehouseId, setFromWarehouseId] = useState('');
  const [toWarehouseId, setToWarehouseId] = useState('');
  const [postToGl, setPostToGl] = useState(false);
  const [contraAccountId, setContraAccountId] = useState('');
  const [editLines, setEditLines] = useState<EditLine[]>([]);

  const { data: move, isLoading } = useQuery({
    queryKey: ['stock-move', id], enabled: !!id,
    queryFn: async (): Promise<Move> => {
      const { data, error } = await supabase.from('stock_moves')
        .select('id, move_no, move_date, move_type, status, description, void_reason').eq('id', id).single();
      if (error) throw error; return data as Move;
    },
  });
  const { data: lines } = useQuery({
    queryKey: ['stock-move-lines', id], enabled: !!id,
    queryFn: async (): Promise<Line[]> => {
      const { data, error } = await supabase.from('stock_move_lines')
        .select('id, line_no, item_id, warehouse_id, direction, entered_qty, unit_cost, item:item_id(code, name_ar), warehouse:warehouse_id(code, name_ar)')
        .eq('move_id', id).order('line_no');
      if (error) throw error; return data as unknown as Line[];
    },
  });
  const { data: warehouses } = useQuery({
    queryKey: ['warehouses', org?.id], enabled: !!org,
    queryFn: async (): Promise<WhOpt[]> => {
      const { data, error } = await supabase.from('warehouses').select('id, code, name_ar').eq('is_active', true).order('code');
      if (error) throw error; return data as WhOpt[];
    },
  });
  const { data: accounts } = useQuery({
    queryKey: ['postable-accounts', org?.id], enabled: !!org,
    queryFn: async (): Promise<AccOpt[]> => {
      const { data, error } = await supabase.from('accounts').select('id, code, name_ar')
        .eq('is_postable', true).eq('allow_transactions', true).order('code');
      if (error) throw error; return data as AccOpt[];
    },
  });

  const isTransfer = move?.move_type === 'transfer';

  useEffect(() => {
    if (!move || !lines) return;
    setDesc(move.description ?? '');
    if (isTransfer) {
      setFromWarehouseId(lines.find((l) => l.direction === 'out')?.warehouse_id ?? '');
      setToWarehouseId(lines.find((l) => l.direction === 'in')?.warehouse_id ?? '');
      const byItem = new Map<string, Line>();
      for (const l of lines) if (l.direction === 'out') byItem.set(l.item_id, l);
      setEditLines([...byItem.values()].map((l) => ({
        key: keySeq++, itemId: l.item_id, itemLabel: `${l.item?.code} · ${l.item?.name_ar}`,
        qty: String(l.entered_qty), unitCost: '', onHand: null,
      })));
    } else {
      setWarehouseId(lines[0]?.warehouse_id ?? '');
      setEditLines(lines.map((l) => ({
        key: keySeq++, itemId: l.item_id, itemLabel: `${l.item?.code} · ${l.item?.name_ar}`,
        qty: String(l.entered_qty), unitCost: l.unit_cost != null ? String(l.unit_cost) : '', onHand: null,
      })));
    }
  }, [move, lines, isTransfer]);

  async function refresh() {
    await qc.invalidateQueries({ queryKey: ['stock-move', id] });
    await qc.invalidateQueries({ queryKey: ['stock-move-lines', id] });
    await qc.invalidateQueries({ queryKey: ['stock-moves'] });
  }

  function setEditLine(key: number, patch: Partial<EditLine>) {
    setEditLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  async function saveDraft() {
    if (!move) return;
    setErr(null); setBusy(true);
    try {
      const valid = editLines.filter((l) => l.itemId && (parseFloat(l.qty) || 0) > 0);
      if (valid.length === 0) throw new Error('أضف سطراً واحداً على الأقل بكمية صحيحة');
      if (isTransfer && (!fromWarehouseId || !toWarehouseId)) throw new Error('اختر مستودع المصدر والوجهة');
      if (!isTransfer && !warehouseId) throw new Error('اختر المستودع');
      if (NEEDS_COST[move.move_type] && valid.some((l) => !(parseFloat(l.unitCost) >= 0))) throw new Error('كل سطر يحتاج تكلفة');

      const { error: uErr } = await supabase.from('stock_moves').update({ description: desc }).eq('id', id);
      if (uErr) throw uErr;
      const { error: dErr } = await supabase.from('stock_move_lines').delete().eq('move_id', id);
      if (dErr) throw dErr;

      let rows: any[];
      if (isTransfer) {
        rows = valid.flatMap((l, i) => [
          { move_id: id, line_no: i * 2 + 1, item_id: l.itemId, warehouse_id: fromWarehouseId, direction: 'out', entered_qty: parseFloat(l.qty), base_qty: parseFloat(l.qty) },
          { move_id: id, line_no: i * 2 + 2, item_id: l.itemId, warehouse_id: toWarehouseId, direction: 'in', entered_qty: parseFloat(l.qty), base_qty: parseFloat(l.qty), unit_cost: 0 },
        ]);
      } else {
        rows = valid.map((l, i) => ({
          move_id: id, line_no: i + 1, item_id: l.itemId, warehouse_id: warehouseId,
          direction: move.move_type === 'adjustment_out' ? 'out' : 'in',
          entered_qty: parseFloat(l.qty), base_qty: parseFloat(l.qty),
          unit_cost: NEEDS_COST[move.move_type] ? parseFloat(l.unitCost) : null,
        }));
      }
      const { error: iErr } = await supabase.from('stock_move_lines').insert(rows);
      if (iErr) throw iErr;
      setEditing(false);
      await refresh();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  async function postDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.rpc('post_stock_move', {
      p_move_id: id,
      p_contra_account_id: !isTransfer && postToGl ? contraAccountId || null : null,
    });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    await refresh();
  }
  async function deleteDraft() {
    setErr(null); setBusy(true);
    const { error } = await supabase.from('stock_moves').delete().eq('id', id);
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    nav('/stock-moves');
  }
  async function voidMove() {
    setErr(null); setBusy(true);
    const { data: newId, error } = await supabase.rpc('void_stock_move', { p_move_id: id, p_date: today(), p_reason: reason || null });
    setBusy(false);
    if (error) return setErr(translateError(error.message));
    if (newId) nav(`/stock-moves/${newId}`); else await refresh();
  }
  async function duplicateToDraft() {
    if (!move || !lines) return;
    setErr(null); setBusy(true);
    try {
      const payload = lines.map((l) => ({
        item_id: l.item_id, warehouse_id: l.warehouse_id, direction: l.direction,
        entered_qty: l.entered_qty, unit_cost: l.direction === 'in' ? l.unit_cost ?? undefined : undefined,
      }));
      const { data: newId, error } = await supabase.rpc('create_stock_move', {
        p_org: org!.id, p_move_type: move.move_type, p_move_date: today(),
        p_description: move.description ? `نسخة عن حركة رقم ${move.move_no} — ${move.description}` : `نسخة عن حركة رقم ${move.move_no}`,
        p_lines: payload,
      });
      if (error) throw error;
      nav(`/stock-moves/${newId}`);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally { setBusy(false); }
  }

  const editTotalQty = useMemo(() => editLines.reduce((s, l) => s + (parseFloat(l.qty) || 0), 0), [editLines]);

  if (isLoading || !move) return <p className="muted">جارٍ التحميل…</p>;

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h1>{TITLE[move.move_type] ?? 'حركة مخزون'} رقم {move.move_no}</h1>
        <span className={`badge ${move.status}`}>{STATUS[move.status]}</span>
      </div>
      <p className="muted">{fmtDate(move.move_date)}</p>

      {move.status === 'draft' && editing ? (
        <div className="card">
          <div className="row">
            <div className="field" style={{ width: 180 }}>
              <label>التاريخ</label>
              <input type="date" value={move.move_date} disabled />
            </div>
            {isTransfer ? (
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
          <div className="field"><label>البيان</label><input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>

          <table style={{ marginTop: '0.5rem' }}>
            <thead>
              <tr>
                <th>الصنف</th>
                <th style={{ width: 110 }} className="num">الكمية</th>
                {NEEDS_COST[move.move_type] && <th style={{ width: 110 }} className="num">تكلفة الوحدة</th>}
                <th style={{ width: 40 }} />
              </tr>
            </thead>
            <tbody>
              {editLines.map((l) => {
                const checkStock = move.move_type === 'adjustment_out' || isTransfer;
                const relevantWarehouse = isTransfer ? fromWarehouseId : warehouseId;
                const qtyNum = parseFloat(l.qty) || 0;
                const overStock = checkStock && l.onHand !== null && qtyNum > l.onHand;
                return (
                  <tr key={l.key}>
                    <td>
                      <ItemPicker
                        initialLabel={l.itemLabel}
                        warehouseId={relevantWarehouse || undefined}
                        onPick={(it) => setEditLine(l.key, { itemId: it.id, itemLabel: `${it.code} · ${it.name_ar}`, onHand: it.onHand })}
                      />
                      {checkStock && l.itemId && l.onHand !== null && (
                        <div className={overStock ? 'error' : 'muted'} style={{ fontSize: '0.78rem', marginTop: '0.2rem' }}>
                          المتوفر: {fmtMoney(l.onHand)}
                        </div>
                      )}
                    </td>
                    <td><input className="num" inputMode="decimal" value={l.qty} onChange={(e) => setEditLine(l.key, { qty: e.target.value })} style={overStock ? { borderColor: 'var(--danger)' } : undefined} /></td>
                    {NEEDS_COST[move.move_type] && <td><input className="num" inputMode="decimal" value={l.unitCost} onChange={(e) => setEditLine(l.key, { unitCost: e.target.value })} /></td>}
                    <td>{editLines.length > 1 && <button type="button" onClick={() => setEditLines((ls) => ls.filter((x) => x.key !== l.key))}>×</button>}</td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot><tr style={{ fontWeight: 700 }}><td>الإجمالي</td><td className="num">{fmtMoney(editTotalQty)}</td><td colSpan={2} /></tr></tfoot>
          </table>
          <button type="button" onClick={() => setEditLines((ls) => [...ls, { key: keySeq++, itemId: '', itemLabel: '', qty: '', unitCost: '', onHand: null }])} style={{ marginTop: '0.5rem' }}>+ سطر</button>

          {err && <p className="error">{err}</p>}
          <div className="row" style={{ marginTop: '1rem' }}>
            <button className="btn-primary" disabled={busy} onClick={saveDraft}>حفظ التعديلات</button>
            <button disabled={busy} onClick={() => { setEditing(false); setErr(null); }}>إلغاء</button>
          </div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: 'auto', marginBottom: '1rem' }}>
          <table>
            <thead><tr><th>الصنف</th><th>المستودع</th><th>الاتجاه</th><th className="num" style={{ width: 110 }}>الكمية</th><th className="num" style={{ width: 110 }}>تكلفة الوحدة</th></tr></thead>
            <tbody>
              {lines?.map((l) => (
                <tr key={l.id}>
                  <td>{l.item?.code} · {l.item?.name_ar}</td>
                  <td>{l.warehouse?.code} · {l.warehouse?.name_ar}</td>
                  <td>{l.direction === 'in' ? 'وارد' : 'صادر'}</td>
                  <td className="num">{fmtMoney(l.entered_qty)}</td>
                  <td className="num">{l.unit_cost != null ? fmtMoney(l.unit_cost) : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {move.status === 'draft' && !editing && (
        <div className="card" style={{ maxWidth: 460 }}>
          {!isTransfer && (
            <div className="row" style={{ alignItems: 'center', marginBottom: '0.75rem' }}>
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
          <div className="row">
            <button className="btn-primary" disabled={busy} onClick={postDraft}>ترحيل</button>
            <button disabled={busy} onClick={() => setEditing(true)}>تعديل</button>
            <button className="btn-danger" disabled={busy} onClick={deleteDraft}>حذف المسودة</button>
          </div>
        </div>
      )}
      {move.status === 'posted' && (
        <div className="card" style={{ maxWidth: 420 }}>
          <h2 style={{ fontSize: '0.95rem' }}>إلغاء الحركة</h2>
          <p className="muted" style={{ fontSize: '0.9rem' }}>بينشئ حركة عكسية (وقيد عكسي إن وُجد) — الحركة الأصلية بتضل موجودة وثابتة.</p>
          <div className="field"><input placeholder="السبب (اختياري)" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {err && <p className="error">{err}</p>}
          <div className="row">
            <button className="btn-danger" disabled={busy} onClick={voidMove}>إلغاء الحركة</button>
            <button disabled={busy} onClick={duplicateToDraft}>نسخ لمسودة جديدة</button>
          </div>
        </div>
      )}
      {move.status === 'void' && (
        <div className="card" style={{ maxWidth: 420 }}>
          <p className="muted">أُلغيت{move.void_reason ? ` — ${move.void_reason}` : ''}.</p>
          {err && <p className="error">{err}</p>}
          <button disabled={busy} onClick={duplicateToDraft}>نسخ لمسودة جديدة</button>
        </div>
      )}
      <p style={{ marginTop: '1rem' }}><Link to="/stock-moves">‹ رجوع لقائمة حركات المخزون</Link></p>
    </>
  );
}
