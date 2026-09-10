'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { Badge, ErrorBox, btn } from '@/components/ui';

export type Action = {
  id: string; recommendation_id: string | null; asin: string; action_type: string; mode: 'dry_run' | 'canary' | 'live'; connector: string; idempotency_key: string;
  payload: Record<string, unknown>; response: Record<string, unknown> | null; status: string; attempt: number; error: string | null;
  before_value: number | null; after_value: number | null; watch_until: string | null; baseline_units_per_day: number | null; created_at: string; finished_at: string | null;
};
export type AutomationPolicy = { automation_live: boolean; canary_asins: string[]; rollback_watch_hours: number; max_live_actions_per_day: number; rollback_units_drop_pct: number };

export const MODE_LABEL: Record<string, string> = { dry_run: 'Chạy thử', canary: 'Canary', live: 'Live' };
export const MODE_CLS: Record<string, string> = { dry_run: 'bg-gray-100 text-gray-700 ring-gray-500/20', canary: 'bg-amber-50 text-amber-800 ring-amber-600/20', live: 'bg-red-50 text-red-700 ring-red-600/20' };
export const ASTATUS: Record<string, { label: string; cls: string }> = {
  queued: { label: 'Chờ', cls: 'bg-gray-100 text-gray-600 ring-gray-500/20' }, running: { label: 'Đang chạy', cls: 'bg-blue-50 text-blue-700 ring-blue-600/20' },
  succeeded: { label: 'Thành công', cls: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' }, failed: { label: 'Lỗi', cls: 'bg-red-50 text-red-700 ring-red-600/20' },
  skipped: { label: 'Bỏ qua', cls: 'bg-gray-100 text-gray-600 ring-gray-500/20' }, rolled_back: { label: 'Đã hoàn tác', cls: 'bg-orange-50 text-orange-700 ring-orange-600/20' },
};

/** Panel thực thi có kiểm soát cho một gợi ý đã duyệt: dry‑run → canary/live → hoàn tác. */
export default function ExecutePanel({ recId, asin, status, canExecute, policy, onChanged }: { recId: string; asin: string; status: string; canExecute: boolean; policy: AutomationPolicy | null; onChanged: () => void }) {
  const [actions, setActions] = React.useState<Action[]>([]);
  const [busy, setBusy] = React.useState<string | null>(null);
  const [err, setErr] = React.useState<string | null>(null);
  const [showPayload, setShowPayload] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    const { data } = await supabase.from('actions').select('*').eq('recommendation_id', recId).order('created_at', { ascending: false });
    setActions((data ?? []) as Action[]);
  }, [recId]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch
    void load();
  }, [load]);

  async function run(mode: 'dry_run' | 'canary' | 'live') {
    if (mode !== 'dry_run' && !confirm(`Thực thi ${MODE_LABEL[mode]} cho ${asin}? Lệnh sẽ ghi thật và được theo dõi ${policy?.rollback_watch_hours ?? 48} giờ để tự hoàn tác nếu units giảm mạnh.`)) return;
    setBusy(mode); setErr(null);
    const { error } = await supabase.rpc('execute_recommendation', { p_rec: recId, p_mode: mode });
    setBusy(null);
    if (error) setErr(error.message); else { await load(); onChanged(); }
  }
  async function rollback(a: Action) {
    const reason = prompt('Lý do hoàn tác:'); if (!reason) return;
    setBusy(a.id); setErr(null);
    const { error } = await supabase.rpc('rollback_action', { p_action: a.id, p_reason: reason, p_trigger: 'manual' });
    setBusy(null);
    if (error) setErr(error.message); else { await load(); onChanged(); }
  }

  const dryOk = actions.some((a) => a.mode === 'dry_run' && a.status === 'succeeded');
  const liveDone = actions.find((a) => a.mode !== 'dry_run' && a.status === 'succeeded');
  const inCanary = policy?.canary_asins?.includes(asin) ?? false;
  const blockers: string[] = [];
  if (status !== 'approved' && !liveDone) blockers.push('gợi ý chưa được duyệt');
  if (!dryOk) blockers.push('chưa chạy thử thành công');
  if (!inCanary) blockers.push('ASIN chưa trong danh sách canary (Chính sách)');
  if (!canExecute) blockers.push('cần quyền theo cấp duyệt');

  return (
    <div className="mt-3 rounded-lg border border-gray-200 bg-gray-50/60 p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs font-semibold uppercase tracking-wide text-gray-600">Thực thi có kiểm soát</span>
        {!liveDone && <>
          <button className={btn.secondary} disabled={busy != null} onClick={() => run('dry_run')}>{busy === 'dry_run' ? '…' : 'Chạy thử (dry‑run)'}</button>
          <button className={btn.primary} disabled={busy != null || blockers.length > 0} onClick={() => run('canary')} title={blockers.join(' · ')}>{busy === 'canary' ? '…' : 'Thực thi canary'}</button>
          <button className={btn.danger} disabled={busy != null || blockers.length > 0 || !policy?.automation_live} onClick={() => run('live')} title={!policy?.automation_live ? 'Live đang tắt trong Chính sách' : blockers.join(' · ')}>{busy === 'live' ? '…' : 'Thực thi live'}</button>
        </>}
        {liveDone && liveDone.status === 'succeeded' && <button className={btn.secondary} disabled={busy != null} onClick={() => rollback(liveDone)}>Hoàn tác…</button>}
      </div>
      {!liveDone && blockers.length > 0 && <p className="text-xs text-gray-500 mt-1">Chưa thể thực thi thật: {blockers.join(' · ')}.</p>}
      {liveDone?.watch_until && <p className="text-xs text-amber-700 mt-1">Đang theo dõi tới {new Date(liveDone.watch_until).toLocaleString('vi-VN')} – tự hoàn tác nếu units/ngày giảm ≥ {policy?.rollback_units_drop_pct ?? 35}% so với 7 ngày trước ({liveDone.baseline_units_per_day ?? '—'} đv/ngày).</p>}
      {err && <div className="mt-2"><ErrorBox message={err} /></div>}
      {actions.length > 0 && (
        <ul className="mt-2 space-y-1">
          {actions.map((a) => (
            <li key={a.id} className="text-xs flex flex-wrap items-center gap-2">
              <Badge className={MODE_CLS[a.mode]}>{MODE_LABEL[a.mode]}</Badge>
              <Badge className={ASTATUS[a.status]?.cls ?? ''}>{ASTATUS[a.status]?.label ?? a.status}</Badge>
              <span className="text-gray-600">{new Date(a.created_at).toLocaleString('vi-VN')} · lần {a.attempt}{a.before_value != null && a.after_value != null && ` · ${a.before_value} → ${a.after_value}`}{a.error && <span className="text-red-600"> · {a.error}</span>}</span>
              <button className="text-indigo-600 hover:underline" onClick={() => setShowPayload(showPayload === a.id ? null : a.id)}>{showPayload === a.id ? 'ẩn' : 'payload'}</button>
              {showPayload === a.id && <pre className="w-full overflow-x-auto rounded bg-white border border-gray-200 p-2 text-[11px] text-gray-700">{JSON.stringify({ idempotency_key: a.idempotency_key, payload: a.payload, response: a.response }, null, 2)}</pre>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
