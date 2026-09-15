import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase.ts';
import { useOrg } from '../lib/org.tsx';
import { fmtDate, translateError } from '../lib/format.ts';

interface Member {
  membership_id: string; user_id: string; email: string; role_id: string; role_code: string;
  role_name: string; is_owner: boolean; is_active: boolean; default_branch_id: string | null;
  branch_name: string | null; created_at: string;
}
interface Invitation {
  id: string; email: string; role_id: string; role_name: string;
  default_branch_id: string | null; branch_name: string | null; invited_by_email: string | null; created_at: string;
}
interface RoleOpt { id: string; code: string; name_ar: string; }
interface BranchOpt { id: string; code: string; name_ar: string; }

export default function Team() {
  const { org } = useOrg();
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteRole, setInviteRole] = useState('');
  const [inviteBranch, setInviteBranch] = useState('');

  const { data: members, isLoading } = useQuery({
    queryKey: ['org-members', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Member[]> => {
      const { data, error } = await supabase.rpc('org_members', { p_org: org!.id });
      if (error) throw error;
      return data as Member[];
    },
  });

  const { data: invitations } = useQuery({
    queryKey: ['pending-invitations', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<Invitation[]> => {
      const { data, error } = await supabase.rpc('org_pending_invitations', { p_org: org!.id });
      if (error) throw error;
      return data as Invitation[];
    },
  });

  const { data: roles } = useQuery({
    queryKey: ['roles-lite', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<RoleOpt[]> => {
      const { data, error } = await supabase.from('roles').select('id, code, name_ar').order('is_system', { ascending: false }).order('name_ar');
      if (error) throw error;
      return data as RoleOpt[];
    },
  });

  const { data: branches } = useQuery({
    queryKey: ['branches-lite', org?.id],
    enabled: !!org,
    queryFn: async (): Promise<BranchOpt[]> => {
      const { data, error } = await supabase.from('branches').select('id, code, name_ar').order('name_ar');
      if (error) throw error;
      return data as BranchOpt[];
    },
  });

  function invalidate() {
    qc.invalidateQueries({ queryKey: ['org-members', org?.id] });
    qc.invalidateQueries({ queryKey: ['pending-invitations', org?.id] });
  }

  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>) {
    setErr(null);
    setBusy(true);
    try {
      const { error } = await fn();
      if (error) throw new Error(error.message);
      invalidate();
    } catch (e) {
      setErr(translateError((e as Error).message));
    } finally {
      setBusy(false);
    }
  }

  async function invite() {
    if (!inviteEmail.trim() || !inviteRole) { setErr('أدخل البريد الإلكتروني واختر الدور'); return; }
    await run(() => supabase.rpc('invite_member', {
      p_org: org!.id, p_email: inviteEmail.trim(), p_role_id: inviteRole,
      p_default_branch_id: inviteBranch || null,
    }));
    setInviteEmail(''); setInviteRole(''); setInviteBranch('');
  }

  return (
    <>
      <h1>الفريق</h1>

      <div className="card">
        <h2>دعوة عضو جديد</h2>
        <div className="row">
          <div className="field grow">
            <label>البريد الإلكتروني</label>
            <input value={inviteEmail} onChange={(e) => setInviteEmail(e.target.value)} placeholder="name@example.com" />
          </div>
          <div className="field" style={{ minWidth: 180 }}>
            <label>الدور</label>
            <select value={inviteRole} onChange={(e) => setInviteRole(e.target.value)}>
              <option value="">—</option>
              {roles?.map((r) => <option key={r.id} value={r.id}>{r.name_ar}</option>)}
            </select>
          </div>
          <div className="field" style={{ minWidth: 180 }}>
            <label>الفرع الافتراضي (اختياري)</label>
            <select value={inviteBranch} onChange={(e) => setInviteBranch(e.target.value)}>
              <option value="">—</option>
              {branches?.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
            </select>
          </div>
          <button className="btn-primary" disabled={busy} onClick={invite} style={{ alignSelf: 'flex-end' }}>دعوة</button>
        </div>
        <p className="muted" style={{ fontSize: '0.85rem', marginTop: '0.25rem' }}>
          إن كان للشخص حساب مسبقاً في النظام تُضاف عضويته فوراً؛ وإلا تبقى الدعوة معلّقة وتُفعَّل تلقائياً بمجرد أن يُنشئ حساباً بنفس البريد الإلكتروني.
        </p>
        {err && <p className="error">{err}</p>}
      </div>

      {!!invitations?.length && (
        <div className="card" style={{ marginTop: '1rem' }}>
          <h2>دعوات معلّقة</h2>
          <div style={{ overflowX: 'auto' }}>
          <table>
            <thead>
              <tr><th>البريد الإلكتروني</th><th>الدور</th><th>الفرع</th><th>بدعوة من</th><th>التاريخ</th><th /></tr>
            </thead>
            <tbody>
              {invitations.map((i) => (
                <tr key={i.id}>
                  <td>{i.email}</td>
                  <td>{i.role_name}</td>
                  <td>{i.branch_name ?? '—'}</td>
                  <td className="muted">{i.invited_by_email ?? '—'}</td>
                  <td className="mono">{fmtDate(i.created_at)}</td>
                  <td>
                    <button disabled={busy} onClick={() => run(() => supabase.rpc('cancel_invitation', { p_invitation_id: i.id }))}>
                      إلغاء الدعوة
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        </div>
      )}

      <div className="card" style={{ marginTop: '1rem', padding: 0, overflowX: 'auto' }}>
        <table>
          <thead>
            <tr><th>البريد الإلكتروني</th><th>الدور</th><th>الفرع</th><th>الحالة</th><th style={{ width: 260 }} /></tr>
          </thead>
          <tbody>
            {isLoading && <tr><td colSpan={5} className="muted">جارٍ التحميل…</td></tr>}
            {members?.map((m) => (
              <tr key={m.membership_id}>
                <td>{m.email}{m.is_owner && <span className="badge posted" style={{ marginInlineStart: '0.4rem' }}>مالك</span>}</td>
                <td>
                  <select
                    value={m.role_id} disabled={busy}
                    onChange={(e) => run(() => supabase.rpc('set_membership_role', { p_membership_id: m.membership_id, p_role_id: e.target.value }))}
                  >
                    {roles?.map((r) => <option key={r.id} value={r.id}>{r.name_ar}</option>)}
                  </select>
                </td>
                <td>
                  <select
                    value={m.default_branch_id ?? ''} disabled={busy}
                    onChange={(e) => run(() => supabase.rpc('set_membership_branch', { p_membership_id: m.membership_id, p_default_branch_id: e.target.value || null }))}
                  >
                    <option value="">—</option>
                    {branches?.map((b) => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
                  </select>
                </td>
                <td>
                  <span className={`badge ${m.is_active ? 'posted' : 'void'}`}>{m.is_active ? 'مفعّل' : 'معطّل'}</span>
                </td>
                <td>
                  <div className="row">
                    <button
                      disabled={busy}
                      onClick={() => run(() => supabase.rpc('set_membership_active', { p_membership_id: m.membership_id, p_is_active: !m.is_active }))}
                    >
                      {m.is_active ? 'تعطيل' : 'تفعيل'}
                    </button>
                    <button
                      className="btn-danger" disabled={busy}
                      onClick={() => {
                        if (confirm(`إزالة ${m.email} من المؤسسة؟`)) run(() => supabase.rpc('remove_membership', { p_membership_id: m.membership_id }));
                      }}
                    >
                      إزالة
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
