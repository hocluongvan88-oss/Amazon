'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { Badge, EmptyState, ErrorBox, btn, input } from '@/components/ui';

export type Task = {
  id: string; sku_id: string | null; asin: string | null; type: string; title: string; description: string | null;
  priority: string; status: string; source_type: string; source_id: string | null; evidence: Record<string, unknown>;
  linked_content_version: string | null; assigned_to: string | null; due_at: string | null; outcome: string | null; created_at: string;
};
export const TASK_TYPE: Record<string, { label: string; cls: string; href?: (t: Task) => string }> = {
  content: { label: 'Content', cls: 'bg-indigo-50 text-indigo-700 ring-indigo-600/20', href: () => '/content' },
  content_opportunity: { label: 'Cơ hội content', cls: 'bg-indigo-50 text-indigo-700 ring-indigo-600/20', href: () => '/content' },
  qa_product: { label: 'QA sản phẩm', cls: 'bg-red-50 text-red-700 ring-red-600/20' },
  ads_guardrail: { label: 'Ads guardrail', cls: 'bg-amber-50 text-amber-800 ring-amber-600/20', href: (t) => `/recommendations?asin=${t.asin ?? ''}` },
  support: { label: 'CSKH', cls: 'bg-sky-50 text-sky-800 ring-sky-600/20', href: () => '/reviews' },
  inventory_investigation: { label: 'Điều tra tồn kho', cls: 'bg-orange-50 text-orange-800 ring-orange-600/20', href: () => '/inventory' },
  other: { label: 'Khác', cls: 'bg-gray-100 text-gray-700 ring-gray-500/20' },
};
export const TASK_STATUS: Record<string, string> = { open: 'Mở', in_progress: 'Đang làm', blocked: 'Bị chặn', done: 'Xong', cancelled: 'Huỷ' };

export default function TaskList({ tasks, canWrite, onChanged, showAsin = true }: { tasks: Task[]; canWrite: boolean; onChanged: () => void; showAsin?: boolean }) {
  const [err, setErr] = React.useState<string | null>(null);
  const [closing, setClosing] = React.useState<{ id: string; status: string } | null>(null);
  const [outcome, setOutcome] = React.useState('');

  async function patch(id: string, p: Record<string, unknown>) {
    setErr(null);
    const { error } = await supabase.from('tasks').update(p).eq('id', id);
    if (error) setErr(error.message); else { setClosing(null); setOutcome(''); onChanged(); }
  }
  if (tasks.length === 0) return <EmptyState title="Không có task" />;
  return (
    <div>
      {err && <div className="p-3"><ErrorBox message={err} /></div>}
      <ul className="divide-y divide-gray-100">
        {tasks.map((t) => {
          const tt = TASK_TYPE[t.type] ?? TASK_TYPE.other;
          const overdue = t.due_at && new Date(t.due_at) < new Date() && !['done', 'cancelled'].includes(t.status);
          const why = t.evidence?.why as string | undefined;
          return (
            <li key={t.id} className="px-4 py-3 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <Badge className={t.priority === 'P0' || t.priority === 'P1' ? 'bg-red-50 text-red-700 ring-red-600/20' : 'bg-gray-100 text-gray-700 ring-gray-500/20'}>{t.priority}</Badge>
                <Badge className={tt.cls}>{tt.label}</Badge>
                <span className={`text-xs px-1.5 py-0.5 rounded ${t.status === 'done' ? 'bg-emerald-50 text-emerald-700' : t.status === 'blocked' ? 'bg-red-50 text-red-700' : 'bg-gray-100 text-gray-700'}`}>{TASK_STATUS[t.status]}</span>
                {showAsin && t.asin && <Link href={t.sku_id ? `/skus/${t.sku_id}` : '#'} className="font-mono text-xs text-indigo-600">{t.asin}</Link>}
                <span className="flex-1" />
                {t.due_at && <span className={`text-xs ${overdue ? 'text-red-600 font-medium' : 'text-gray-400'}`}>{overdue ? 'Quá hạn ' : 'Hạn '}{new Date(t.due_at).toLocaleDateString('vi-VN')}</span>}
              </div>
              <p className="font-medium text-gray-900 mt-1">{t.title}</p>
              {(t.description || why) && <p className="text-xs text-gray-600 whitespace-pre-line">{t.description ?? why}</p>}
              <p className="text-[11px] text-gray-400 mt-0.5">Nguồn: {t.source_type === 'voc_ticket' ? 'ticket VoC' : t.source_type === 'listing_audit' ? 'listing audit' : t.source_type}{t.outcome && ` · Kết quả: ${t.outcome}`}</p>
              {canWrite && !['done', 'cancelled'].includes(t.status) && (
                <div className="mt-2 flex flex-wrap gap-2 items-center">
                  {tt.href && <Link href={tt.href(t)} className={btn.ghost}>Mở nơi xử lý →</Link>}
                  {t.status === 'open' && <button className={btn.secondary} onClick={() => patch(t.id, { status: 'in_progress' })}>Bắt đầu</button>}
                  {t.status !== 'blocked' && <button className={btn.secondary} onClick={() => patch(t.id, { status: 'blocked' })}>Chặn</button>}
                  {t.status === 'blocked' && <button className={btn.secondary} onClick={() => patch(t.id, { status: 'in_progress' })}>Bỏ chặn</button>}
                  <button className={btn.success} onClick={() => setClosing({ id: t.id, status: 'done' })}>Xong…</button>
                  <button className={btn.ghost} onClick={() => setClosing({ id: t.id, status: 'cancelled' })}>Huỷ…</button>
                </div>
              )}
              {closing?.id === t.id && (
                <div className="mt-2 flex flex-wrap gap-2 items-center">
                  <input autoFocus value={outcome} onChange={(e) => setOutcome(e.target.value)} className={`${input} flex-1 min-w-60`} placeholder={closing.status === 'done' ? 'Kết quả (bắt buộc): đã làm gì, tác động' : 'Lý do huỷ (bắt buộc)'} />
                  <button className={btn.primary} disabled={outcome.trim().length < 3} onClick={() => patch(t.id, { status: closing.status, outcome: outcome.trim() })}>Xác nhận</button>
                  <button className={btn.ghost} onClick={() => setClosing(null)}>Bỏ</button>
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
