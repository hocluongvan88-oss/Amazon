'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { useTenant, ROLE_LABEL, ROLE_DESC, type Role } from '@/lib/tenant';
import { Card, CardHeader, Badge, Spinner, ErrorBox, EmptyState, btn, input } from '@/components/ui';

type Member = { user_id: string; role: Role; created_at: string };
type Delegation = {
  id: string; grantor_id: string; grantee_id: string; permission_key: string; reason: string;
  starts_at: string; expires_at: string; revoked_at: string | null;
};
type MatrixRow = { key: string; domain: string; description: string; roles: string[] | null };

const ROLES = Object.keys(ROLE_LABEL) as Role[];
const DELEGABLE = [
  ['content.brand_approve', 'Duyệt cuối content (brand uỷ quyền cho Vexim)'],
  ['content.publish', 'Ghi nhận publish listing / A+'],
  ['rec.approve_l2', 'Duyệt cấp L2'],
  ['rec.approve_l1', 'Duyệt cấp L1'],
  ['cogs.write', 'Ghi COGS / phí'],
  ['voc.approve_response', 'Duyệt phản hồi khách hàng'],
] as const;

export default function MembersManager() {
  const { tenant, user, can, permissions } = useTenant();
  const canManage = can('member.manage');
  const [members, setMembers] = React.useState<Member[]>([]);
  const [delegs, setDelegs] = React.useState<Delegation[]>([]);
  const [matrix, setMatrix] = React.useState<MatrixRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [ok, setOk] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [email, setEmail] = React.useState('');
  const [role, setRole] = React.useState<Role>('operator');
  const [dEmail, setDEmail] = React.useState('');
  const [dPerm, setDPerm] = React.useState<string>(DELEGABLE[0][0]);
  const [dReason, setDReason] = React.useState('');
  const [dDays, setDDays] = React.useState(30);
  const [showMatrix, setShowMatrix] = React.useState(false);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [m, d, x] = await Promise.all([
      supabase.from('tenant_members').select('user_id, role, created_at').eq('tenant_id', tenant.id).limit(500),
      supabase.from('permission_delegations').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(200),
      supabase.from('v_role_matrix').select('*').order('domain').limit(200),
    ]);
    if (m.error) setError(m.error.message); else setMembers((m.data ?? []) as Member[]);
    setDelegs((d.data ?? []) as Delegation[]);
    setMatrix((x.data ?? []) as MatrixRow[]);
    setLoading(false);
  }, [tenant]);

  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    if (!tenant) return;
    setBusy(true); setError(null); setOk(null);
    const { error: err } = await supabase.rpc('add_member_by_email', { t: tenant.id, member_email: email.trim(), member_role: role });
    setBusy(false);
    if (err) setError(err.message); else { setOk(`Đã thêm ${email} với vai trò ${ROLE_LABEL[role]}.`); setEmail(''); load(); }
  }

  async function changeRole(user_id: string, r: Role) {
    if (!tenant) return;
    const { error: err } = await supabase.from('tenant_members').update({ role: r }).eq('tenant_id', tenant.id).eq('user_id', user_id);
    if (err) setError(err.message); else load();
  }

  async function remove(user_id: string) {
    if (!tenant || !confirm('Gỡ thành viên này khỏi brand?')) return;
    const { error: err } = await supabase.from('tenant_members').delete().eq('tenant_id', tenant.id).eq('user_id', user_id);
    if (err) setError(err.message); else load();
  }

  async function grant(e: React.FormEvent) {
    e.preventDefault();
    if (!tenant) return;
    setBusy(true); setError(null); setOk(null);
    const { error: err } = await supabase.rpc('grant_delegation', { t: tenant.id, grantee_email: dEmail.trim(), perm: dPerm, p_reason: dReason.trim(), p_days: dDays });
    setBusy(false);
    if (err) setError(err.message); else { setOk(`Đã uỷ quyền ${dPerm} cho ${dEmail} trong ${dDays} ngày.`); setDEmail(''); setDReason(''); load(); }
  }

  async function revoke(id: string) {
    if (!confirm('Thu hồi uỷ quyền này?')) return;
    const { error: err } = await supabase.rpc('revoke_delegation', { p_id: id });
    if (err) setError(err.message); else load();
  }

  if (loading) return <Spinner />;

  const owners = members.filter((m) => m.role === 'owner').length;
  const hasBrandApprover = members.some((m) => m.role === 'brand_approver');
  const activeDelegs = delegs.filter((d) => !d.revoked_at && new Date(d.expires_at) > new Date());
  const canDelegateAny = DELEGABLE.some(([k]) => permissions.has(k)) && (can('delegation.grant') || permissions.has('content.brand_approve'));
  const who = (id: string) => (id === user?.id ? `${user?.email} (bạn)` : id.slice(0, 8) + '…');

  return (
    <div className="space-y-6">
      {error && <ErrorBox message={error} />}
      {ok && <p className="text-sm text-emerald-700">{ok}</p>}

      {!hasBrandApprover && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <b>Chưa có Brand Approver.</b> Content (listing / A+) sẽ dừng ở trạng thái <i>chờ brand duyệt</i> và không thể publish.
          Mời người của khách hàng với vai trò <b>Brand Approver</b>, hoặc để brand uỷ quyền có thời hạn cho Ops Lead của Vexim (mục Uỷ quyền).
        </div>
      )}

      <div className="grid lg:grid-cols-3 gap-6">
        <Card className="lg:col-span-2">
          <CardHeader title={`Thành viên của ${tenant?.name}`} subtitle={`${members.length} người · quyền theo hành động, giới hạn trong tenant này`} />
          <ul className="divide-y divide-gray-100">
            {members.map((m) => {
              const me = m.user_id === user?.id;
              const lastOwner = m.role === 'owner' && owners === 1;
              return (
                <li key={m.user_id} className="px-5 py-3 flex flex-wrap items-center gap-3">
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-gray-900 font-mono truncate">{me ? user?.email : m.user_id}</p>
                    <p className="text-xs text-gray-500">{ROLE_DESC[m.role]} · tham gia {new Date(m.created_at).toLocaleDateString('vi-VN')}{me && ' · bạn'}</p>
                  </div>
                  {canManage ? (
                    <>
                      <select value={m.role} disabled={lastOwner} onChange={(e) => changeRole(m.user_id, e.target.value as Role)} className={`${input} w-44`}>
                        {ROLES.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
                      </select>
                      <button className={btn.secondary} disabled={lastOwner} onClick={() => remove(m.user_id)} title={lastOwner ? 'Không thể gỡ owner cuối cùng' : ''}>Gỡ</button>
                    </>
                  ) : <Badge className="bg-gray-50 text-gray-700 ring-gray-500/20">{ROLE_LABEL[m.role]}</Badge>}
                </li>
              );
            })}
          </ul>
          <p className="px-5 py-3 text-xs text-gray-500 border-t border-gray-100">
            Nguyên tắc tách trách nhiệm: người tạo/gửi không tự duyệt; người soạn phản hồi không tự duyệt; chỉ Finance ghi COGS; chỉ Brand Approver publish content.
          </p>
        </Card>

        <Card>
          <CardHeader title="Thêm thành viên" subtitle="Người đó cần đăng nhập ít nhất một lần trước" />
          {canManage ? (
            <form onSubmit={add} className="p-5 space-y-3">
              <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} className={input} placeholder="email@congty.com" />
              <select value={role} onChange={(e) => setRole(e.target.value as Role)} className={input}>
                {ROLES.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
              </select>
              <p className="text-xs text-gray-500">{ROLE_DESC[role]}</p>
              <button className={`${btn.primary} w-full justify-center`} disabled={busy}>{busy ? 'Đang thêm…' : 'Thêm'}</button>
            </form>
          ) : <div className="p-5 text-sm text-gray-500">Cần quyền <code>member.manage</code> (Owner).</div>}
          <div className="px-5 pb-5 text-xs text-gray-500 space-y-1">
            {ROLES.map((r) => (
              <p key={r}><Badge className="bg-gray-50 text-gray-700 ring-gray-500/20">{ROLE_LABEL[r]}</Badge> {ROLE_DESC[r]}</p>
            ))}
          </div>
        </Card>
      </div>

      <div className="grid lg:grid-cols-3 gap-6">
        <Card className="lg:col-span-2">
          <CardHeader title="Uỷ quyền tạm thời" subtitle="Có thời hạn (≤ 90 ngày), có lý do, ghi audit. Thu hồi được bất cứ lúc nào." />
          {delegs.length === 0 ? <EmptyState title="Chưa có uỷ quyền nào" /> : (
            <ul className="divide-y divide-gray-100">
              {delegs.map((d) => {
                const active = !d.revoked_at && new Date(d.expires_at) > new Date();
                return (
                  <li key={d.id} className="px-5 py-3 flex flex-wrap items-center gap-3 text-sm">
                    <div className="flex-1 min-w-0">
                      <p className="font-medium text-gray-900"><code>{d.permission_key}</code> → {who(d.grantee_id)}</p>
                      <p className="text-xs text-gray-500">bởi {who(d.grantor_id)} · {new Date(d.starts_at).toLocaleDateString('vi-VN')} → {new Date(d.expires_at).toLocaleDateString('vi-VN')} · {d.reason}</p>
                    </div>
                    <Badge className={active ? 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' : 'bg-gray-100 text-gray-600 ring-gray-500/20'}>
                      {d.revoked_at ? 'Đã thu hồi' : active ? 'Hiệu lực' : 'Hết hạn'}
                    </Badge>
                    {active && (d.grantor_id === user?.id || canManage) && <button className={btn.secondary} onClick={() => revoke(d.id)}>Thu hồi</button>}
                  </li>
                );
              })}
            </ul>
          )}
          <p className="px-5 py-3 text-xs text-gray-500 border-t border-gray-100">{activeDelegs.length} uỷ quyền đang hiệu lực.</p>
        </Card>

        <Card>
          <CardHeader title="Tạo uỷ quyền" subtitle="Chỉ uỷ quyền được permission bạn đang có" />
          {canDelegateAny ? (
            <form onSubmit={grant} className="p-5 space-y-3">
              <input type="email" required value={dEmail} onChange={(e) => setDEmail(e.target.value)} className={input} placeholder="email thành viên nhận" />
              <select value={dPerm} onChange={(e) => setDPerm(e.target.value)} className={input}>
                {DELEGABLE.filter(([k]) => permissions.has(k)).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
              </select>
              <input type="number" min={1} max={90} value={dDays} onChange={(e) => setDDays(Number(e.target.value))} className={input} placeholder="Số ngày" />
              <textarea required minLength={5} value={dReason} onChange={(e) => setDReason(e.target.value)} className={`${input} h-20`} placeholder="Lý do uỷ quyền (bắt buộc, ≥ 5 ký tự)" />
              <button className={`${btn.primary} w-full justify-center`} disabled={busy}>{busy ? 'Đang tạo…' : 'Uỷ quyền'}</button>
            </form>
          ) : <div className="p-5 text-sm text-gray-500">Bạn không có permission nào uỷ quyền được (cần <code>delegation.grant</code> hoặc là Brand Approver).</div>}
        </Card>
      </div>

      <Card>
        <CardHeader title="Ma trận quyền" subtitle="Nguồn sự thật từ DB (role_permissions)"
          action={<button className={btn.ghost} onClick={() => setShowMatrix((v) => !v)}>{showMatrix ? 'Ẩn' : 'Hiện'}</button>} />
        {showMatrix && (
          <div className="overflow-x-auto">
            <table className="min-w-full text-xs">
              <thead className="bg-gray-50 text-gray-500">
                <tr>
                  <th className="px-4 py-2 text-left">Permission</th>
                  {ROLES.map((r) => <th key={r} className="px-2 py-2 text-center">{ROLE_LABEL[r]}</th>)}
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100">
                {matrix.map((row) => (
                  <tr key={row.key}>
                    <td className="px-4 py-1.5"><code>{row.key}</code> <span className="text-gray-500">— {row.description}</span></td>
                    {ROLES.map((r) => <td key={r} className="px-2 py-1.5 text-center">{row.roles?.includes(r) ? '✓' : ''}</td>)}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
