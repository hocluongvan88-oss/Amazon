'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { LIMITS } from '@/lib/limits';
import { Paged } from '@/components/ShowMore';
import TaskList, { TASK_TYPE, type Task } from '@/components/TaskList';
import { Card, CardHeader, Spinner, ErrorBox, btn, input } from '@/components/ui';

export default function TasksQueue() {
  const { tenant, can } = useTenant();
  const [tasks, setTasks] = React.useState<Task[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [type, setType] = React.useState('all');
  const [showClosed, setShowClosed] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const { data, error: e } = await supabase.from('tasks').select('*').eq('tenant_id', tenant.id).order('status').order('priority').order('due_at').limit(LIMITS.maxFetch);
    if (e) setError(e.message); else { setError(null); setTasks((data ?? []) as Task[]); }
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function scanOpportunities() {
    if (!tenant) return;
    setBusy(true); setMsg(null);
    const { data, error: e } = await supabase.rpc('create_content_opportunity_tasks', { t: tenant.id, p_min_score: 50 });
    setBusy(false);
    if (e) setError(e.message); else { setMsg(`Đã tạo ${data} task cơ hội content (điểm ≥ 50).`); load(); }
  }

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error.includes('tasks') ? 'Chưa chạy migration 014_tasks_control_room.sql' : error} />;

  const canWrite = can('voc.triage') || can('content.draft') || can('exception.resolve');
  const list = tasks.filter((t) => (type === 'all' || t.type === type) && (showClosed || !['done', 'cancelled'].includes(t.status)));
  const counts = tasks.filter((t) => !['done', 'cancelled'].includes(t.status)).reduce<Record<string, number>>((m, t) => ((m[t.type] = (m[t.type] ?? 0) + 1), m), {});

  return (
    <Card>
      <CardHeader title={`${list.length} task`} subtitle={Object.entries(counts).map(([k, n]) => `${TASK_TYPE[k]?.label ?? k}: ${n}`).join(' · ') || 'Không có task mở'}
        action={<div className="flex gap-2 items-center">
          <select value={type} onChange={(e) => setType(e.target.value)} className={`${input} w-44`}><option value="all">Mọi loại</option>{Object.entries(TASK_TYPE).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</select>
          <label className="text-sm flex items-center gap-1"><input type="checkbox" checked={showClosed} onChange={(e) => setShowClosed(e.target.checked)} className="rounded" />Đã đóng</label>
          {can('content.draft') && <button className={btn.secondary} disabled={busy} onClick={scanOpportunities}>{busy ? '…' : 'Quét cơ hội content'}</button>}
        </div>} />
      {msg && <p className="px-4 pt-3 text-sm text-emerald-700">{msg}</p>}
      <Paged items={list} page={LIMITS.listPage} label="task">{(visible) => <TaskList tasks={visible} canWrite={canWrite} onChanged={load} />}</Paged>
    </Card>
  );
}
