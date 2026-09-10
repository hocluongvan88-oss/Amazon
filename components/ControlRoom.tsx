'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { usd } from '@/lib/format';
import TaskList, { type Task } from '@/components/TaskList';
import { Card, CardHeader, Spinner, ErrorBox } from '@/components/ui';

type Room = {
  sku: { is_canary: boolean };
  revenue: { units_30d: number | null; revenue_30d: number | null; cp_30d: number | null; velocity_change_pct: number | null; cvr_30: number | null };
  margin: { cp_margin_now_pct: number | null; margin_delta_pts: number | null; min_margin_pct: number | null; below_min: boolean };
  ads: { ad_spend_30: number | null; acos_30: number | null; tacos_30: number | null; break_even_acos_pct: number | null };
  inventory: { days_of_cover: number | null; stockout_eta: string | null; health: string | null };
  risk: { score: number | null };
  content: { facts_verified: number; facts_proposed: number; published: Record<string, number>; in_flight: number; opportunity_score: number | null; reasons: string[] | null };
  voc: { neg_reviews_90d: number; open_tickets: number; top_topics: { code: string; n: number }[] };
  queue: { recommendations_pending: number; exceptions_open: number; tasks_open: number; tasks_by_type: Record<string, number> };
  actions: { last_action: { type: string; mode: string; status: string; at: string } | null; in_watch: number };
  signals: { level: 'high' | 'medium' | 'low' | 'info'; msg: string }[];
};

const LVL: Record<string, string> = { high: 'bg-red-50 text-red-800 border-red-200', medium: 'bg-amber-50 text-amber-800 border-amber-200', low: 'bg-gray-50 text-gray-700 border-gray-200', info: 'bg-sky-50 text-sky-800 border-sky-200' };
function Tile({ title, href, children }: { title: string; href: string; children: React.ReactNode }) {
  return (
    <Link href={href} className="block rounded-lg border border-gray-200 bg-white p-3 hover:border-indigo-300 transition">
      <p className="text-[11px] uppercase tracking-wide text-gray-500">{title}</p>
      <div className="mt-1 text-sm text-gray-800 space-y-0.5">{children}</div>
    </Link>
  );
}
const pct = (x: number | null | undefined, d = 1) => (x == null ? '—' : `${Number(x).toFixed(d)}%`);

export default function ControlRoom({ skuId, asin, canWrite }: { skuId: string; asin: string; canWrite: boolean }) {
  const [room, setRoom] = React.useState<Room | null>(null);
  const [tasks, setTasks] = React.useState<Task[]>([]);
  const [err, setErr] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);

  const load = React.useCallback(async () => {
    const [r, t] = await Promise.all([
      supabase.rpc('asin_control_room', { p_sku: skuId }),
      supabase.from('tasks').select('*').eq('sku_id', skuId).order('status').order('priority').limit(50),
    ]);
    if (r.error) setErr(r.error.message); else setRoom(r.data as Room);
    setTasks((t.data ?? []) as Task[]);
    setLoading(false);
  }, [skuId]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on sku change
    void load();
  }, [load]);

  if (loading) return <Spinner label="Đang tổng hợp Control Room…" />;
  if (err) return <ErrorBox message={err.includes('asin_control_room') ? 'Chưa chạy migration 014_tasks_control_room.sql' : err} />;
  if (!room) return null;

  const openTasks = tasks.filter((t) => !['done', 'cancelled'].includes(t.status));

  return (
    <Card className="mb-6">
      <CardHeader title="ASIN Control Room" subtitle="Doanh thu · biên · ads · tồn kho · content · VoC · hàng đợi — một chỗ, cùng tín hiệu chéo giữa các miền" />
      <div className="p-5 space-y-4">
        {room.signals.length > 0 ? (
          <ul className="grid sm:grid-cols-2 gap-2">
            {room.signals.map((s, i) => <li key={i} className={`rounded-md border px-3 py-2 text-sm ${LVL[s.level]}`}>{s.level === 'high' ? '⛔' : s.level === 'medium' ? '⚠' : 'ℹ'} {s.msg}</li>)}
          </ul>
        ) : <p className="text-sm text-emerald-700">Không có tín hiệu bất thường.</p>}

        <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-3">
          <Tile title="Doanh thu 30 ngày" href={`/profit-bridge`}>
            <p><b>{room.revenue.units_30d ?? '—'}</b> đv · {usd(room.revenue.revenue_30d, 0)}</p>
            <p>CP {usd(room.revenue.cp_30d, 0)} · velocity {room.revenue.velocity_change_pct == null ? '—' : `${room.revenue.velocity_change_pct > 0 ? '+' : ''}${Number(room.revenue.velocity_change_pct).toFixed(0)}%`}</p>
            <p>CVR {pct(room.revenue.cvr_30 == null ? null : room.revenue.cvr_30 * 100)}</p>
          </Tile>
          <Tile title="Biên & Ads" href={`/profit-bridge`}>
            <p className={room.margin.below_min ? 'text-red-700 font-medium' : ''}>Biên {pct(room.margin.cp_margin_now_pct)} (min {pct(room.margin.min_margin_pct, 0)})</p>
            <p>Δ baseline {room.margin.margin_delta_pts == null ? '—' : `${Number(room.margin.margin_delta_pts).toFixed(1)} pts`}</p>
            <p>ACoS {pct(room.ads.acos_30)} / break‑even {pct(room.ads.break_even_acos_pct)} · TACoS {pct(room.ads.tacos_30)}</p>
          </Tile>
          <Tile title="Tồn kho & rủi ro" href={`/inventory`}>
            <p>{room.inventory.days_of_cover == null ? '—' : `${Number(room.inventory.days_of_cover).toFixed(0)} ngày tồn`} · {room.inventory.health ?? '—'}</p>
            <p>Hết hàng dự kiến: {room.inventory.stockout_eta ? new Date(room.inventory.stockout_eta).toLocaleDateString('vi-VN') : '—'}</p>
            <p>Risk {room.risk.score == null ? '—' : Number(room.risk.score).toFixed(0)}{room.sku.is_canary && ' · canary'}</p>
          </Tile>
          <Tile title="Content" href={`/content`}>
            <p>{room.content.facts_verified} fact ✓{room.content.facts_proposed > 0 && ` · ${room.content.facts_proposed} chờ`}</p>
            <p>Publish: {Object.keys(room.content.published).length ? Object.entries(room.content.published).map(([k, v]) => `${k} v${v}`).join(', ') : 'chưa ghi nhận'}</p>
            <p>{room.content.in_flight} đang xử lý · cơ hội {room.content.opportunity_score ?? '—'}</p>
          </Tile>
          <Tile title="Voice of Customer" href={`/reviews`}>
            <p>{room.voc.neg_reviews_90d} review ≤3★ / 90 ngày · {room.voc.open_tickets} ticket mở</p>
            <p className="text-xs text-gray-500">{room.voc.top_topics.length ? room.voc.top_topics.map((t) => `${t.code} (${t.n})`).join(' · ') : 'không có chủ đề tiêu cực'}</p>
          </Tile>
          <Tile title="Hàng đợi quyết định" href={`/recommendations?asin=${asin}`}>
            <p>{room.queue.recommendations_pending} khuyến nghị chờ · {room.queue.exceptions_open} exception mở</p>
            <p>{room.queue.tasks_open} task mở{Object.keys(room.queue.tasks_by_type).length ? ` (${Object.entries(room.queue.tasks_by_type).map(([k, v]) => `${k}: ${v}`).join(', ')})` : ''}</p>
          </Tile>
          <Tile title="Hành động gần nhất" href={`/actions`}>
            {room.actions.last_action ? <p>{room.actions.last_action.type} · {room.actions.last_action.mode} · {room.actions.last_action.status}<br /><span className="text-xs text-gray-500">{room.actions.last_action.at ? new Date(room.actions.last_action.at).toLocaleString('vi-VN') : ''}</span></p> : <p className="text-gray-500">Chưa có hành động thật</p>}
            {room.actions.in_watch > 0 && <p className="text-sky-700">{room.actions.in_watch} đang theo dõi rollback</p>}
          </Tile>
        </div>

        <div>
          <p className="text-sm font-medium text-gray-900 mb-1">Task của ASIN ({openTasks.length} mở)</p>
          <div className="rounded-lg border border-gray-200">
            <TaskList tasks={openTasks} canWrite={canWrite} onChanged={load} showAsin={false} />
          </div>
        </div>
      </div>
    </Card>
  );
}
