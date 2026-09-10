'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { Badge, ErrorBox, btn } from '@/components/ui';

export type Action = {
  id: string; recommendation_id: string | null; asin: string; action_type: string; mode: 'dry_run' | 'canary' | 'live'; connector: string; idempotency_key: string;
  execution_channel: 'internal_record' | 'manual_seller_central' | 'sp_api'; amazon_applied: boolean; manual_evidence: string | null; manual_confirmed_at: string | null;
  payload: Record<string, unknown>; response: Record<string, unknown> | null; status: string; attempt: number; error: string | null;
  before_value: number | null; after_value: number | null; watch_until: string | null; baseline_units_per_day: number | null; created_at: string; finished_at: string | null;
};
export type AutomationPolicy = { automation_live: boolean; canary_asins: string[]; rollback_watch_hours: number; max_live_actions_per_day: number; rollback_units_drop_pct: number };

export const MODE_LABEL: Record<string, string> = { dry_run: 'Chạy thử', canary: 'Canary (ghi nhận nội bộ)', live: 'Live (API)' };
export const CHANNEL_LABEL: Record<string, string> = { internal_record: 'Ghi nhận nội bộ — chưa tác động Amazon', manual_seller_central: 'Đã thực hiện tay trên Seller Central', sp_api: 'Qua SP‑API' };
export const CHANNEL_CLS: Record<string, string> = { internal_record: 'bg-gray-100 text-gray-700 ring-gray-500/20', manual_seller_central: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20', sp_api: 'bg-indigo-50 text-indigo-700 ring-indigo-600/20' };
export const MODE_CLS: Record<string, string> = { dry_run: 'bg-gray-100 text-gray-700 ring-gray-500/20', canary: 'bg-amber-50 text-amber-800 ring-amber-600/20', live: 'bg-red-50 text-red-700 ring-red-600/20' };
export const ASTATUS: Record<string, { label: string; cls: string }> = {
  queued: { label: 'Chờ', cls: 'bg-gray-100 text-gray-600 ring-gray-500/20' }, running: { label: 'Đang chạy', cls: 'bg-blue-50 text-blue-700 ring-blue-600/20' },
  succeeded: { label: 'Đã ghi nhận', cls: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' }, failed: { label: 'Lỗi', cls: 'bg-red-50 text-red-700 ring-red-600/20' },
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
    if (mode === 'canary' && !confirm(`Ghi nhận canary cho ${asin}? Hệ thống chỉ cập nhật DB nội bộ — KHÔNG tác động Amazon. Bạn cần thực hiện tay trên Seller Central rồi bấm "Xác nhận đã làm trên Seller Central". Theo dõi ${policy?.rollback_watch_hours ?? 48} giờ để tự hoàn tác nếu units giảm mạnh.`)) return;
    if (mode === 'live' && !confirm(`Thực thi live qua SP‑API cho ${asin}?`)) return;
    setBusy(mode); setErr(null);
    const { error } = await supabase.rpc('execute_recommendation', { p_rec: recId, p_mode: mode });
    setBusy(null);
    if (error) setErr(error.message); else { await load(); onChanged(); }
  }
  async function confirmManual(a: Action) {
    const ev = prompt('Bằng chứng đã thực hiện trên Seller Central (URL hoặc ghi chú ≥ 5 ký tự):'); if (!ev) return;
    setBusy(a.id); setErr(null);
    const { error } = await supabase.rpc('confirm_manual_execution', { p_action: a.id, p_evidence: ev });
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
          <button className={btn.danger} disabled title="Chưa có kết nối SP‑API — live bị khoá (Phase 0). Canary chỉ ghi nhận nội bộ.">Live (API) — chưa khả dụng</button>
        </>}
        {liveDone && liveDone.status === 'succeeded' && liveDone.execution_channel === 'internal_record' && <button className={btn.primary} disabled={busy != null} onClick={() => confirmManual(liveDone)}>Xác nhận đã làm trên Seller Central…</button>}
        {liveDone && liveDone.status === 'succeeded' && <button className={btn.secondary} disabled={busy != null} onClick={() => rollback(liveDone)}>Hoàn tác…</button>}
      </div>
      {liveDone && <p className="text-xs mt-1"><Badge className={CHANNEL_CLS[liveDone.execution_channel]}>{CHANNEL_LABEL[liveDone.execution_channel]}</Badge>{liveDone.manual_evidence && <span className="text-gray-600 ml-2">Bằng chứng: {liveDone.manual_evidence}</span>}</p>}
      {!liveDone && blockers.length > 0 && <p className="text-xs text-gray-500 mt-1">Chưa thể thực thi thật: {blockers.join(' · ')}.</p>}
      {liveDone?.watch_until && <p className="text-xs text-amber-700 mt-1">Đang theo dõi tới {new Date(liveDone.watch_until).toLocaleString('vi-VN')} – tự hoàn tác nếu units/ngày giảm ≥ {policy?.rollback_units_drop_pct ?? 35}% so với 7 ngày trước ({liveDone.baseline_units_per_day ?? '—'} đv/ngày).</p>}
      {err && <div className="mt-2"><ErrorBox message={err} /></div>}
      {actions.length > 0 && (
        <ul className="mt-2 space-y-1">
          {actions.map((a) => (
            <li key={a.id} className="text-xs flex flex-wrap items-center gap-2">
              <Badge className={MODE_CLS[a.mode]}>{MODE_LABEL[a.mode]}</Badge>
              <Badge className={ASTATUS[a.status]?.cls ?? ''}>{ASTATUS[a.status]?.label ?? a.status}</Badge>
              {a.mode !== 'dry_run' && <Badge className={CHANNEL_CLS[a.execution_channel]}>{a.amazon_applied ? 'Đã áp dụng trên Amazon' : 'Chưa tác động Amazon'}</Badge>}
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
