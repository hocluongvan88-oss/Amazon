'use client';

import React from 'react';
import { LIMITS } from '@/lib/limits';
import { Paged } from '@/components/ShowMore';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, EmptyState, Spinner, ErrorBox, btn } from '@/components/ui';
import { type Action, MODE_LABEL, MODE_CLS, ASTATUS } from '@/components/ExecutePanel';

type Stats = { dry_runs: number; canary_runs: number; live_runs: number; failed: number; rolled_back: number; uncontrolled_writes: number; live_last_24h: number; last_live_at: string | null };
type Rollback = { id: string; action_id: string; trigger: string; reason: string; restored_value: number | null; metrics: Record<string, unknown> | null; created_at: string };
const TYPE_LABEL: Record<string, string> = { price_update: 'Đổi giá', replenish_po: 'Đơn nhập hàng', inventory_note: 'Ghi chú' };
const TRIGGER_LABEL: Record<string, string> = { manual: 'Thủ công', auto_metric: 'Tự động (metric)', auto_error: 'Tự động (lỗi)' };

export default function ActionsLog() {
  const { tenant, canWrite } = useTenant();
  const [actions, setActions] = React.useState<Action[]>([]);
  const [rollbacks, setRollbacks] = React.useState<Rollback[]>([]);
  const [stats, setStats] = React.useState<Stats | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [mode, setMode] = React.useState('real');
  const [open, setOpen] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState(false);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [a, r, s] = await Promise.all([
      supabase.from('actions').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(LIMITS.maxFetch),
      supabase.from('rollbacks').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(LIMITS.maxFetch),
      supabase.from('v_automation_stats').select('*').eq('tenant_id', tenant.id).maybeSingle(),
    ]);
    if (a.error) setError(a.error.message); else setActions((a.data ?? []) as Action[]);
    setRollbacks((r.data ?? []) as Rollback[]); setStats((s.data as Stats) ?? null); setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch
    void load();
  }, [load]);

  async function checkRollbacks() {
    if (!tenant) return; setBusy(true);
    const { data, error: e } = await supabase.rpc('check_auto_rollbacks', { t: tenant.id });
    setBusy(false); if (e) setError(e.message); else { alert(`Đã kiểm tra – ${data ?? 0} lệnh bị hoàn tác tự động.`); load(); }
  }
  async function rollback(a: Action) {
    const reason = prompt('Lý do hoàn tác:'); if (!reason) return;
    const { error: e } = await supabase.rpc('rollback_action', { p_action: a.id, p_reason: reason, p_trigger: 'manual' });
    if (e) setError(e.message); else load();
  }

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;
  const list = actions.filter((a) => mode === 'all' || (mode === 'real' ? a.mode !== 'dry_run' : a.mode === mode));
  const rbByAction = Object.fromEntries(rollbacks.map((r) => [r.action_id, r]));
  const watching = actions.filter((a) => a.status === 'succeeded' && a.watch_until && new Date(a.watch_until) > new Date());

  return (
    <>
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">
        <Kpi label="Lệnh ngoài kiểm soát" v={stats?.uncontrolled_writes ?? 0} tone={stats?.uncontrolled_writes ? 'red' : 'green'} hint="ghi thật không gắn gợi ý đã duyệt – phải = 0" />
        <Kpi label="Canary / Live" v={`${stats?.canary_runs ?? 0} / ${stats?.live_runs ?? 0}`} hint={`${stats?.dry_runs ?? 0} lượt chạy thử`} />
        <Kpi label="Đã hoàn tác" v={stats?.rolled_back ?? 0} hint={`${rollbacks.filter((r) => r.trigger !== 'manual').length} tự động`} tone={stats?.rolled_back ? 'amber' : 'default'} />
        <Kpi label="Đang theo dõi" v={watching.length} hint="trong cửa sổ tự hoàn tác" />
        <Card className="p-4">
          <p className="text-xs text-gray-500">24 giờ qua</p>
          <p className="text-2xl font-bold mt-1 text-gray-900">{stats?.live_last_24h ?? 0} <span className="text-sm font-medium text-gray-500">lệnh thật</span></p>
          {canWrite && <button className={`${btn.ghost} px-0 mt-1`} disabled={busy} onClick={checkRollbacks}>{busy ? '…' : 'Kiểm tra auto‑rollback →'}</button>}
        </Card>
      </div>

      <div className="flex flex-wrap gap-2 mb-3 text-sm">
        {[['real', 'Canary + Live'], ['dry_run', 'Chạy thử'], ['all', 'Tất cả']].map(([k, l]) => (
          <button key={k} onClick={() => setMode(k)} className={`px-3 py-1.5 rounded-lg border ${mode === k ? 'bg-gray-900 text-white border-gray-900' : 'bg-white text-gray-700 border-gray-200 hover:bg-gray-50'}`}>{l}</button>
        ))}
      </div>

      <Card>
        <CardHeader title="Nhật ký lệnh" subtitle="Mỗi lệnh có khoá idempotency – gọi lại không tạo lệnh thứ hai" />
        {list.length === 0 ? <EmptyState title="Chưa có lệnh" description="Thực thi từ trang Gợi ý & phê duyệt (gợi ý đã duyệt → Chạy thử → Canary)." /> : (
          <Paged items={list} page={LIMITS.feed} label="lệnh">{(visible) => (<ul className="divide-y divide-gray-100">
            {visible.map((a) => { const rb = rbByAction[a.id]; return (
              <li key={a.id} className="px-5 py-3">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge className={MODE_CLS[a.mode]}>{MODE_LABEL[a.mode]}</Badge>
                  <Badge className={ASTATUS[a.status]?.cls ?? ''}>{ASTATUS[a.status]?.label ?? a.status}</Badge>
                  <span className="text-sm font-medium text-gray-900">{TYPE_LABEL[a.action_type] ?? a.action_type}</span>
                  <span className="font-mono text-xs text-gray-500">{a.asin}</span>
                  {a.before_value != null && a.after_value != null && <span className="text-sm tabular-nums">{a.before_value} → <b>{a.after_value}</b></span>}
                  <span className="text-xs text-gray-400">{new Date(a.created_at).toLocaleString('vi-VN')} · {a.connector} · lần {a.attempt}</span>
                  {a.watch_until && new Date(a.watch_until) > new Date() && <Badge className="bg-amber-50 text-amber-800 ring-amber-600/20">theo dõi tới {new Date(a.watch_until).toLocaleString('vi-VN', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}</Badge>}
                  <span className="ml-auto flex gap-2">
                    {a.recommendation_id && <Link href={`/recommendations?asin=${a.asin}`} className={btn.ghost}>Gợi ý</Link>}
                    <button className={btn.ghost} onClick={() => setOpen(open === a.id ? null : a.id)}>{open === a.id ? 'Ẩn' : 'Chi tiết'}</button>
                    {canWrite && a.status === 'succeeded' && a.mode !== 'dry_run' && <button className={btn.secondary} onClick={() => rollback(a)}>Hoàn tác…</button>}
                  </span>
                </div>
                {a.error && <p className="text-xs text-red-600 mt-1">{a.error}</p>}
                {rb && <p className="text-xs text-orange-700 mt-1">Hoàn tác {TRIGGER_LABEL[rb.trigger]} · {new Date(rb.created_at).toLocaleString('vi-VN')} · {rb.reason}</p>}
                {open === a.id && <pre className="mt-2 overflow-x-auto rounded bg-gray-50 border border-gray-200 p-2 text-[11px] text-gray-700">{JSON.stringify({ idempotency_key: a.idempotency_key, payload: a.payload, response: a.response, baseline_units_per_day: a.baseline_units_per_day }, null, 2)}</pre>}
              </li>
            ); })}
          </ul>)}</Paged>
        )}
      </Card>
    </>
  );
}

function Kpi({ label, v, hint, tone }: { label: string; v: React.ReactNode; hint?: string; tone?: 'red' | 'amber' | 'green' | 'default' }) {
  return <Card className="p-4"><p className="text-xs text-gray-500">{label}</p><p className={`text-2xl font-bold mt-1 ${tone === 'red' ? 'text-red-600' : tone === 'amber' ? 'text-amber-700' : tone === 'green' ? 'text-emerald-700' : 'text-gray-900'}`}>{v}</p>{hint && <p className="text-xs text-gray-500 mt-0.5">{hint}</p>}</Card>;
}
