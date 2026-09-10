'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { useTenant, ROLE_LABEL, type Role } from '@/lib/tenant';
import { Card, CardHeader, Badge, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Member = { user_id: string; role: Role; created_at: string; email?: string };

export default function MembersManager() {
  const { tenant, user } = useTenant();
  const isOwner = tenant?.role === 'owner';
  const [members, setMembers] = React.useState<Member[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [email, setEmail] = React.useState('');
  const [role, setRole] = React.useState<Role>('operator');
  const [busy, setBusy] = React.useState(false);
  const [ok, setOk] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const { data, error: e } = await supabase.from('tenant_members').select('user_id, role, created_at').eq('tenant_id', tenant.id);
    if (e) setError(e.message); else setMembers((data ?? []) as Member[]);
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

  if (loading) return <Spinner />;
  if (!isOwner) return <ErrorBox message="Chỉ Owner mới quản lý thành viên." />;

  const owners = members.filter((m) => m.role === 'owner').length;

  return (
    <div className="grid lg:grid-cols-3 gap-6">
      <Card className="lg:col-span-2">
        <CardHeader title={`Thành viên của ${tenant?.name}`} subtitle={`${members.length} người`} />
        {error && <div className="p-4"><ErrorBox message={error} /></div>}
        <ul className="divide-y divide-gray-100">
          {members.map((m) => {
            const me = m.user_id === user?.id;
            const lastOwner = m.role === 'owner' && owners === 1;
            return (
              <li key={m.user_id} className="px-5 py-3 flex flex-wrap items-center gap-3">
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-gray-900 font-mono truncate">{me ? user?.email : m.user_id}</p>
                  <p className="text-xs text-gray-500">Tham gia {new Date(m.created_at).toLocaleDateString('vi-VN')}{me && ' · bạn'}</p>
                </div>
                <select value={m.role} disabled={lastOwner} onChange={(e) => changeRole(m.user_id, e.target.value as Role)} className={`${input} w-36`}>
                  {(Object.keys(ROLE_LABEL) as Role[]).map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
                </select>
                <button className={btn.secondary} disabled={lastOwner} onClick={() => remove(m.user_id)} title={lastOwner ? 'Không thể gỡ owner cuối cùng' : ''}>Gỡ</button>
              </li>
            );
          })}
        </ul>
        <p className="px-5 py-3 text-xs text-gray-500 border-t border-gray-100">
          Vì lý do bảo mật, email của thành viên khác không hiển thị từ trình duyệt (chỉ ID). Sẽ bổ sung khi có server action.
        </p>
      </Card>

      <Card>
        <CardHeader title="Thêm thành viên" subtitle="Người đó cần đăng nhập ít nhất một lần trước" />
        <form onSubmit={add} className="p-5 space-y-3">
          <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} className={input} placeholder="email@congty.com" />
          <select value={role} onChange={(e) => setRole(e.target.value as Role)} className={input}>
            {(Object.keys(ROLE_LABEL) as Role[]).map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
          </select>
          <button className={`${btn.primary} w-full justify-center`} disabled={busy}>{busy ? 'Đang thêm…' : 'Thêm'}</button>
          {ok && <p className="text-sm text-emerald-700">{ok}</p>}
        </form>
        <div className="px-5 pb-5 text-xs text-gray-500 space-y-1">
          <p><Badge className="bg-gray-50 text-gray-700 ring-gray-500/20">Owner</Badge> duyệt L2, quản lý thành viên</p>
          <p><Badge className="bg-gray-50 text-gray-700 ring-gray-500/20">Operator</Badge> vận hành, duyệt L0–L1</p>
          <p><Badge className="bg-gray-50 text-gray-700 ring-gray-500/20">Viewer</Badge> chỉ xem</p>
        </div>
      </Card>
    </div>
  );
}
