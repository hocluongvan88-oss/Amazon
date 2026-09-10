'use client';

import React from 'react';
import { LIMITS } from '@/lib/limits';
import { Paged } from '@/components/ShowMore';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Exc = {
  id: string; code: string; message: string; asin: string | null; sku_id: string | null; sku_title: string | null; rule_code: string | null;
  resolved: boolean; auto_resolved: boolean; created_at: string; due_at: string | null; overdue: boolean; hours_left: number | null; snoozed: boolean; snoozed_until: string | null;
  assigned_to: string | null; feedback: string | null; feedback_note: string | null; resolution_note: string | null; context: Record<string, unknown> | null;
  recommendation_id: string | null;
};
type Member = { user_id: string; role: string };
type Prec = { rule_code: string; opened: number; tp: number; fp: number; auto_closed: number; precision_pct: number | null };
type Run = { started_at: string; finished_at: string | null; trigger: string; skus_scanned: number; exceptions_opened: number; exceptions_closed: number; recs_created: number };

const CODE_CLS: Record<string, string> = {
  P0: 'bg-red-600 text-white ring-red-700', P1: 'bg-red-50 text-red-700 ring-red-600/20',
  P2: 'bg-yellow-50 text-yellow-800 ring-yellow-600/20', P3: 'bg-gray-50 text-gray-700 ring-gray-500/20',
};
export const RULE_LABEL: Record<string, string> = {
  STOCKOUT_IMMINENT: 'Sắp hết hàng', BELOW_REORDER_POINT: 'Dưới điểm đặt hàng', OVERSTOCK: 'Tồn dư', MARGIN_EROSION: 'Xói mòn biên',
  VELOCITY_DROP: 'Sụt tốc độ bán', NO_SALES_7D: 'Không bán 7 ngày', PRICE_VOLATILITY: 'Giá biến động', DATA_STALE: 'Dữ liệu cũ', REVIEW_CLUSTER: 'Cụm review tiêu cực',
};

export default function ExceptionsList() {
  const { tenant, can, user } = useTenant();
  const canWrite = can('exception.resolve');
  const [items, setItems] = React.useState<Exc[]>([]);
  const [members, setMembers] = React.useState<Member[]>([]);
  const [prec, setPrec] = React.useState<Prec[]>([]);
  const [lastRun, setLastRun] = React.useState<Run | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [showResolved, setShowResolved] = React.useState(false);
  const [onlyMine, setOnlyMine] = React.useState(false);
  const [ruleFilter, setRuleFilter] = React.useState('all');
  const [running, setRunning] = React.useState(false);
  const [closing, setClosing] = React.useState<Exc | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [q, m, p, r] = await Promise.all([
      supabase.from('v_exception_queue').select('*').eq('tenant_id', tenant.id).order('resolved').order('code').order('due_at').limit(LIMITS.maxFetch),
      supabase.from('tenant_members').select('user_id, role').eq('tenant_id', tenant.id),
      supabase.from('v_rule_precision').select('*').eq('tenant_id', tenant.id),
      supabase.from('rule_runs').select('*').eq('tenant_id', tenant.id).order('started_at', { ascending: false }).limit(1).maybeSingle(),
    ]);
    if (q.error) setError(q.error.message); else setItems((q.data ?? []) as Exc[]);
    setMembers((m.data ?? []) as Member[]);
    setPrec((p.data ?? []) as Prec[]);
    setLastRun((r.data as Run) ?? null);
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function patch(id: string, p: Record<string, unknown>) {
    const { error: e } = await supabase.from('exceptions').update(p).eq('id', id);
    if (e) setError(e.message); else load();
  }
  async function runRules() {
    if (!tenant) return;
    setRunning(true);
    const { data, error: e } = await supabase.rpc('run_rules', { t: tenant.id, p_trigger: 'manual' });
    setRunning(false);
    if (e) setError(e.message); else { const r = data as Run; setLastRun(r); load(); }
  }

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  const open = items.filter((i) => !i.resolved);
  const overdue = open.filter((i) => i.overdue).length;
  const list = items
    .filter((i) => showResolved || !i.resolved)
    .filter((i) => !onlyMine || i.assigned_to === user?.id)
    .filter((i) => ruleFilter === 'all' || i.rule_code === ruleFilter)
    .sort((a, b) => Number(a.resolved) - Number(b.resolved) || Number(b.overdue) - Number(a.overdue) || a.code.localeCompare(b.code) || (a.hours_left ?? 1e9) - (b.hours_left ?? 1e9));

  return (
    <>
      {/* Summary strip */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        <Stat label="Đang mở" v={open.length} />
        <Stat label="Quá hạn SLA" v={overdue} tone={overdue ? 'red' : 'default'} />
        <Stat label="P0 / P1 mở" v={`${open.filter((i) => i.code === 'P0').length} / ${open.filter((i) => i.code === 'P1').length}`} />
        <Card className="p-4">
          <p className="text-xs text-gray-500">Rule engine</p>
          <p className="text-sm text-gray-900 mt-1">{lastRun ? <>Chạy {new Date(lastRun.started_at).toLocaleString('vi-VN')} · {lastRun.skus_scanned} SKU · +{lastRun.exceptions_opened}/−{lastRun.exceptions_closed} · {lastRun.recs_created} gợi ý</> : 'Chưa chạy'}</p>
          {canWrite && <button className={`${btn.ghost} mt-1 px-0`} disabled={running} onClick={runRules}>{running ? 'Đang chạy…' : 'Chạy ngay →'}</button>}
        </Card>
      </div>

      <div className="flex flex-wrap items-center gap-3 mb-4 text-sm">
        <select value={ruleFilter} onChange={(e) => setRuleFilter(e.target.value)} className={`${input} w-52`}>
          <option value="all">Mọi rule</option>
          {Object.entries(RULE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <label className="inline-flex items-center gap-2"><input type="checkbox" checked={onlyMine} onChange={(e) => setOnlyMine(e.target.checked)} className="rounded" />Của tôi</label>
        <label className="inline-flex items-center gap-2"><input type="checkbox" checked={showResolved} onChange={(e) => setShowResolved(e.target.checked)} className="rounded" />Hiện đã xử lý</label>
      </div>

      <div className="grid lg:grid-cols-3 gap-4">
        <Card className="lg:col-span-2">
          {list.length === 0 ? <EmptyState title="Không có ngoại lệ nào" description="Mọi thứ đang trong ngưỡng chính sách." /> : (
            <Paged items={list} page={LIMITS.listPage} label="ngoại lệ">{(visible) => (<ul className="divide-y divide-gray-100">
              {visible.map((e) => (
                <li key={e.id} className={`px-5 py-4 ${e.resolved ? 'opacity-60' : ''} ${e.overdue ? 'bg-red-50/40' : ''}`}>
                  <div className="flex flex-wrap items-start gap-3">
                    <Badge className={CODE_CLS[e.code] ?? CODE_CLS.P3}>{e.code}</Badge>
                    <div className="flex-1 min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        {e.rule_code && <span className="text-xs font-semibold uppercase tracking-wide text-indigo-600">{RULE_LABEL[e.rule_code] ?? e.rule_code}</span>}
                        {e.overdue && <Badge className="bg-red-50 text-red-700 ring-red-600/20">Quá hạn {Math.abs(Math.round((e.hours_left ?? 0) / 24 * 10) / 10)} ngày</Badge>}
                        {!e.resolved && !e.overdue && e.hours_left != null && <span className="text-xs text-gray-500">còn {e.hours_left < 48 ? `${Math.round(e.hours_left)} giờ` : `${Math.round(e.hours_left / 24)} ngày`}</span>}
                        {e.snoozed && <Badge className="bg-gray-50 text-gray-600 ring-gray-500/20">Tạm hoãn tới {new Date(e.snoozed_until!).toLocaleDateString('vi-VN')}</Badge>}
                        {e.resolved && <Badge className={e.auto_resolved ? 'bg-gray-50 text-gray-600 ring-gray-500/20' : e.feedback === 'false_positive' ? 'bg-orange-50 text-orange-700 ring-orange-600/20' : 'bg-emerald-50 text-emerald-700 ring-emerald-600/20'}>{e.auto_resolved ? 'Tự đóng' : e.feedback === 'false_positive' ? 'Cảnh báo sai' : 'Đã xử lý'}</Badge>}
                      </div>
                      <p className="text-sm font-medium text-gray-900 mt-0.5">{e.message}</p>
                      <p className="text-xs text-gray-500 mt-0.5">
                        {e.sku_id ? <Link href={`/skus/${e.sku_id}`} className="hover:underline"><span className="font-mono">{e.asin}</span> · {e.sku_title}</Link> : e.asin}
                        {' · '}{new Date(e.created_at).toLocaleString('vi-VN')}
                        {e.resolution_note && <> · {e.resolution_note}</>}
                        {e.feedback_note && <> · “{e.feedback_note}”</>}
                      </p>
                    </div>
                    {canWrite && !e.resolved && (
                      <div className="flex flex-wrap items-center gap-2 shrink-0">
                        <select value={e.assigned_to ?? ''} onChange={(ev) => patch(e.id, { assigned_to: ev.target.value || null })} className={`${input} w-36 text-xs`} title="Gán người xử lý">
                          <option value="">— chưa gán —</option>
                          {members.map((m) => <option key={m.user_id} value={m.user_id}>{m.user_id === user?.id ? 'Tôi' : `${m.role} · ${m.user_id.slice(0, 6)}`}</option>)}
                        </select>
                        <select value="" onChange={(ev) => ev.target.value && patch(e.id, { snoozed_until: new Date(Date.now() + Number(ev.target.value) * 86400000).toISOString() })} className={`${input} w-28 text-xs`}>
                          <option value="">Hoãn…</option><option value="1">1 ngày</option><option value="3">3 ngày</option><option value="7">7 ngày</option>
                        </select>
                        {e.asin && <Link href={`/recommendations?asin=${e.asin}`} className={btn.secondary}>Gợi ý</Link>}
                        <button className={btn.success} onClick={() => setClosing(e)}>Đóng…</button>
                      </div>
                    )}
                    {canWrite && e.resolved && !e.auto_resolved && <button className={btn.secondary} onClick={() => patch(e.id, { resolved: false, feedback: null, feedback_note: null, resolution_note: null })}>Mở lại</button>}
                  </div>
                </li>
              ))}
            </ul>)}</Paged>
          )}
        </Card>

        <Card className="self-start">
          <CardHeader title="Độ chính xác theo rule" subtitle="Gate tuần 5–6: operator đánh dấu đúng/sai khi đóng" />
          {prec.length === 0 ? <p className="p-5 text-sm text-gray-500">Chưa có dữ liệu.</p> : (
            <table className="w-full text-sm">
              <thead className="text-xs uppercase text-gray-500 bg-gray-50"><tr><th className="px-4 py-2 text-left">Rule</th><th className="px-2 py-2 text-right">Mở</th><th className="px-2 py-2 text-right">Đúng</th><th className="px-2 py-2 text-right">Sai</th><th className="px-4 py-2 text-right">Precision</th></tr></thead>
              <tbody className="divide-y divide-gray-100">
                {prec.map((p) => (
                  <tr key={p.rule_code}>
                    <td className="px-4 py-2">{RULE_LABEL[p.rule_code] ?? p.rule_code}</td>
                    <td className="px-2 py-2 text-right tabular-nums">{p.opened}</td>
                    <td className="px-2 py-2 text-right tabular-nums text-emerald-700">{p.tp}</td>
                    <td className="px-2 py-2 text-right tabular-nums text-orange-700">{p.fp}</td>
                    <td className={`px-4 py-2 text-right tabular-nums font-medium ${p.precision_pct == null ? 'text-gray-400' : p.precision_pct >= 70 ? 'text-emerald-700' : 'text-red-600'}`}>{p.precision_pct != null ? `${p.precision_pct}%` : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <p className="px-4 py-3 text-xs text-gray-500 border-t border-gray-100">Cảnh báo bị đánh dấu sai sẽ không mở lại trong thời gian cooldown (Chính sách). Ngoại lệ tự đóng không tính vào precision.</p>
        </Card>
      </div>

      {closing && (
        <CloseDialog exc={closing} onCancel={() => setClosing(null)}
          onSubmit={(fb, note) => { const id = closing.id; setClosing(null); patch(id, { resolved: true, feedback: fb, feedback_note: note || null, resolution_note: fb === 'true_positive' ? 'Đã xử lý' : 'Cảnh báo không đúng' }); }} />
      )}
    </>
  );
}

function Stat({ label, v, tone = 'default' }: { label: string; v: React.ReactNode; tone?: 'default' | 'red' }) {
  return <Card className="p-4"><p className="text-xs text-gray-500">{label}</p><p className={`text-2xl font-bold mt-1 ${tone === 'red' ? 'text-red-600' : 'text-gray-900'}`}>{v}</p></Card>;
}

function CloseDialog({ exc, onCancel, onSubmit }: { exc: Exc; onCancel: () => void; onSubmit: (fb: 'true_positive' | 'false_positive', note: string) => void }) {
  const [fb, setFb] = React.useState<'true_positive' | 'false_positive'>('true_positive');
  const [note, setNote] = React.useState('');
  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4" onClick={onCancel}>
      <div className="bg-white rounded-xl shadow-xl w-full max-w-md p-5" onClick={(e) => e.stopPropagation()}>
        <h3 className="font-semibold text-gray-900">Đóng ngoại lệ</h3>
        <p className="text-sm text-gray-600 mt-1">{exc.message}</p>
        <div className="mt-4 space-y-2">
          <label className="flex items-start gap-2 text-sm"><input type="radio" checked={fb === 'true_positive'} onChange={() => setFb('true_positive')} className="mt-1" /><span><b>Cảnh báo đúng</b> – đã xử lý / đã có hành động</span></label>
          <label className="flex items-start gap-2 text-sm"><input type="radio" checked={fb === 'false_positive'} onChange={() => setFb('false_positive')} className="mt-1" /><span><b>Cảnh báo sai</b> – không cần hành động (rule sẽ tạm không mở lại)</span></label>
        </div>
        <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} className={`${input} mt-3`} placeholder={fb === 'true_positive' ? 'Đã làm gì? (tuỳ chọn)' : 'Vì sao sai? (giúp tinh chỉnh ngưỡng)'} />
        <div className="mt-4 flex justify-end gap-2"><button className={btn.secondary} onClick={onCancel}>Huỷ</button><button className={btn.success} disabled={fb === 'false_positive' && note.trim().length < 3} onClick={() => onSubmit(fb, note.trim())}>Xác nhận</button></div>
      </div>
    </div>
  );
}
