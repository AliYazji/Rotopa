import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { translateError } from '../lib/format.ts';

interface Role { id: string; code: string; name_ar: string; is_system: boolean; }
interface Perm { key: string; module: string; description_ar: string; is_dangerous: boolean; }

const MODULE_LABEL: Record<string, string> = {
  platform: 'المنصة والإدارة',
  accounting: 'المحاسبة والمخزون',
  hr: 'الموارد البشرية',
  hotel: 'الفندقة',
  pos: 'الكاشير والمطعم',
};

export default function Roles() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [selected, setSelected] = useState<string | null>(null);
  const [newName, setNewName] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const { data: roles } = useQuery({
    queryKey: ['roles', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Role[]> => {
      const { data, error } = await supabase.from('roles').select('id, code, name_ar, is_system').order('is_system', { ascending: false }).order('name_ar');
      if (error) throw error;
      return data as Role[];
    },
  });

  const { data: allPerms } = useQuery({
    queryKey: ['permissions'],
    queryFn: async (): Promise<Perm[]> => {
      const { data, error } = await supabase.from('permissions').select('key, module, description_ar, is_dangerous').order('module').order('key');
      if (error) throw error;
      return data as Perm[];
    },
  });

  const { data: granted } = useQuery({
    queryKey: ['role-permissions', selected],
    enabled: !!selected,
    queryFn: async (): Promise<Set<string>> => {
      const { data, error } = await supabase.from('role_permissions').select('permission_key').eq('role_id', selected!);
      if (error) throw error;
      return new Set((data as { permission_key: string }[]).map((r) => r.permission_key));
    },
  });

  const grouped = useMemo(() => {
    const byModule = new Map<string, Perm[]>();
    for (const p of allPerms ?? []) {
      if (!byModule.has(p.module)) byModule.set(p.module, []);
      byModule.get(p.module)!.push(p);
    }
    return byModule;
  }, [allPerms]);

  const role = roles?.find((r) => r.id === selected);

  async function toggle(key: string, on: boolean) {
    if (!selected || role?.is_system) return;
    setErr(null); setBusy(true);
    try {
      const { error } = on
        ? await supabase.from('role_permissions').insert({ role_id: selected, permission_key: key })
        : await supabase.from('role_permissions').delete().eq('role_id', selected).eq('permission_key', key);
      if (error) throw new Error(error.message);
      qc.invalidateQueries({ queryKey: ['role-permissions', selected] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  async function createRole() {
    if (!org || !newName.trim()) return;
    setErr(null); setBusy(true);
    try {
      const code = newName.trim().toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '') || 'role';
      const { data, error } = await supabase.from('roles')
        .insert({ org_id: org.id, code, name_ar: newName.trim(), is_system: false })
        .select('id').single();
      if (error) throw new Error(error.message);
      setNewName('');
      qc.invalidateQueries({ queryKey: ['roles', org.id] });
      setSelected(data.id);
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  async function deleteRole(id: string) {
    if (!confirm('حذف هذا الدور؟ لا يمكن الحذف إن كان مُسنداً لأي عضو حالياً.')) return;
    setErr(null); setBusy(true);
    try {
      const { error } = await supabase.from('roles').delete().eq('id', id);
      if (error) throw new Error(error.message);
      if (selected === id) setSelected(null);
      qc.invalidateQueries({ queryKey: ['roles', org?.id] });
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h1>الأدوار والصلاحيات</h1>
      <div className="row" style={{ alignItems: 'flex-start', gap: '1rem' }}>
        <div className="card" style={{ width: 260, flexShrink: 0, padding: '0.5rem' }}>
          {roles?.map((r) => (
            <div
              key={r.id}
              onClick={() => setSelected(r.id)}
              className="row"
              style={{
                justifyContent: 'space-between', padding: '0.5rem 0.6rem', borderRadius: 8, cursor: 'pointer',
                background: selected === r.id ? 'var(--surface-2)' : 'transparent',
              }}
            >
              <span>{r.name_ar} {r.is_system && <span className="badge" style={{ marginInlineStart: '0.3rem' }}>نظامي</span>}</span>
            </div>
          ))}
          <div className="row" style={{ marginTop: '0.75rem', padding: '0 0.4rem' }}>
            <input className="grow" placeholder="اسم دور جديد" value={newName} onChange={(e) => setNewName(e.target.value)} />
            <button disabled={busy || !newName.trim()} onClick={createRole}>+ إضافة</button>
          </div>
        </div>

        <div className="card grow">
          {!role && <p className="muted">اختر دوراً من القائمة لعرض صلاحياته.</p>}
          {role && (
            <>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <h2>{role.name_ar}</h2>
                {!role.is_system && (
                  <button className="btn-danger" disabled={busy} onClick={() => deleteRole(role.id)}>حذف الدور</button>
                )}
              </div>
              {role.is_system && <p className="muted" style={{ fontSize: '0.85rem' }}>هذا دور نظامي أساسي — صلاحياته ثابتة ولا يمكن تعديلها.</p>}
              {err && <p className="error">{err}</p>}

              {[...grouped.entries()].map(([mod, perms]) => (
                <div key={mod} style={{ marginTop: '1rem' }}>
                  <h3 style={{ fontSize: '0.95rem' }}>{MODULE_LABEL[mod] ?? mod}</h3>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: '0.4rem 1rem' }}>
                    {perms.map((p) => (
                      <label key={p.key} className="row" style={{ gap: '0.5rem', fontWeight: 400, marginBottom: 0 }}>
                        <input
                          type="checkbox"
                          style={{ width: 'auto' }}
                          checked={granted?.has(p.key) ?? false}
                          disabled={busy || role.is_system}
                          onChange={(e) => toggle(p.key, e.target.checked)}
                        />
                        <span>{p.description_ar}{p.is_dangerous && <span className="badge void" style={{ marginInlineStart: '0.3rem', fontSize: '0.68rem' }}>حساس</span>}</span>
                      </label>
                    ))}
                  </div>
                </div>
              ))}
            </>
          )}
        </div>
      </div>
    </>
  );
}
