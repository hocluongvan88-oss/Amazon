'use client';

import React from 'react';
import { LIMITS } from '@/lib/limits';
import { Paged } from '@/components/ShowMore';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Review = {
  id: string; asin: string; sku_id: string | null; sku_title: string | null; rating: number; title: string | null; body: string; verified_purchase: boolean;
  reviewed_at: string | null; created_at: string; topics: string[] | null; severity: number | null; has_ticket: boolean; draft_status: string | null; qa_done: boolean;
};
type Topic = { code: string; label: string; type: string };
type Summary = { asin: string; topic_code: string; label: string; type: string; reviews: number; reviews_30d: number; reviews_90d: number; avg_rating: number; max_severity: number; last_seen: string };
type Ticket = { id: string; asin: string; sku_id: string | null; type: string; topic_code: string | null; priority: string; status: string; title: string; description: string | null; review_ids: string[]; assigned_to: string | null; created_at: string; resolution_note: string | null };
type Draft = { id: string; review_id: string; ticket_id: string | null; body: string; channel: string; status: string; policy_check: { ok: boolean; violations: string[]; warnings: string[] } | null; created_by: string | null; approved_by: string | null; rejected_reason: string | null; created_at: string };
type Cls = { id: string; review_id: string; topic_code: string; severity: number; confidence: number; method: string; matched: string[] | null; verified_ok: boolean | null; verified_at: string | null };
type Prec = { topic_code: string; total: number; verified: number; correct: number; precision_pct: number | null };
type Member = { user_id: string; role: string };

const TYPE_LABEL: Record<string, string> = { defect: 'Chất lượng sản phẩm', content: 'Nội dung listing (mô tả/ảnh)', logistics: 'Fulfillment & đóng gói', service: 'Dịch vụ khách hàng', positive: 'Điểm khách khen', other: 'Khác' };
const TYPE_CLS: Record<string, string> = { defect: 'bg-red-50 text-red-700 ring-red-600/20', content: 'bg-amber-50 text-amber-800 ring-amber-600/20', logistics: 'bg-blue-50 text-blue-700 ring-blue-600/20', service: 'bg-purple-50 text-purple-700 ring-purple-600/20', positive: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20', other: 'bg-gray-100 text-gray-600 ring-gray-500/20' };
const TSTATUS: Record<string, { label: string; cls: string }> = { open: { label: 'Mở', cls: 'bg-red-50 text-red-700 ring-red-600/20' }, investigating: { label: 'Đang xử lý', cls: 'bg-amber-50 text-amber-800 ring-amber-600/20' }, resolved: { label: 'Đã xử lý', cls: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' }, wont_fix: { label: 'Không xử lý', cls: 'bg-gray-100 text-gray-600 ring-gray-500/20' } };
const DSTATUS: Record<string, { label: string; cls: string }> = { draft: { label: 'Nháp', cls: 'bg-gray-100 text-gray-600 ring-gray-500/20' }, pending_approval: { label: 'Chờ duyệt', cls: 'bg-amber-50 text-amber-800 ring-amber-600/20' }, approved: { label: 'Đã duyệt', cls: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' }, rejected: { label: 'Từ chối', cls: 'bg-red-50 text-red-700 ring-red-600/20' }, sent: { label: 'Đã gửi', cls: 'bg-indigo-50 text-indigo-700 ring-indigo-600/20' } };
const Stars = ({ n }: { n: number }) => <span className={`tabular-nums font-semibold ${n <= 2 ? 'text-red-600' : n === 3 ? 'text-amber-600' : 'text-emerald-700'}`}>{n}★</span>;

export default function ReviewsVoc() {
  const { tenant, canWrite, user } = useTenant();
  const [tab, setTab] = React.useState<'triage' | 'topics' | 'tickets' | 'drafts' | 'qa'>('triage');
  const [reviews, setReviews] = React.useState<Review[]>([]);
  const [topics, setTopics] = React.useState<Topic[]>([]);
  const [summary, setSummary] = React.useState<Summary[]>([]);
  const [tickets, setTickets] = React.useState<Ticket[]>([]);
  const [drafts, setDrafts] = React.useState<Draft[]>([]);
  const [prec, setPrec] = React.useState<Prec[]>([]);
  const [members, setMembers] = React.useState<Member[]>([]);
  const [maxRating, setMaxRating] = React.useState(3);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [sel, setSel] = React.useState<Review | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [now] = React.useState(() => Date.now());

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [r, t, s, k, d, p, m, po] = await Promise.all([
      supabase.from('v_review_triage').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(LIMITS.maxFetch),
      supabase.from('review_topics').select('code,label,type').eq('tenant_id', tenant.id).eq('active', true),
      supabase.from('v_review_topic_summary').select('*').eq('tenant_id', tenant.id),
      supabase.from('voc_tickets').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(LIMITS.maxFetch),
      supabase.from('response_drafts').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(LIMITS.maxFetch),
      supabase.from('v_classification_precision').select('*').eq('tenant_id', tenant.id),
      supabase.from('tenant_members').select('user_id, role').eq('tenant_id', tenant.id),
      supabase.from('policy_register').select('review_triage_max_rating').eq('tenant_id', tenant.id).maybeSingle(),
    ]);
    if (r.error) setError(r.error.message); else setReviews((r.data ?? []) as Review[]);
    setTopics((t.data ?? []) as Topic[]); setSummary((s.data ?? []) as Summary[]); setTickets((k.data ?? []) as Ticket[]);
    setDrafts((d.data ?? []) as Draft[]); setPrec((p.data ?? []) as Prec[]); setMembers((m.data ?? []) as Member[]);
    if (po.data?.review_triage_max_rating) setMaxRating(po.data.review_triage_max_rating);
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch on tenant change
    void load();
  }, [load]);

  async function reclassify() {
    if (!tenant) return; setBusy(true);
    const { error: e } = await supabase.rpc('classify_reviews', { t: tenant.id, only_new: false });
    await supabase.rpc('run_review_rules', { t: tenant.id });
    setBusy(false); if (e) setError(e.message); else load();
  }

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  const topicMap = Object.fromEntries(topics.map((t) => [t.code, t]));
  const low = reviews.filter((r) => r.rating <= maxRating);
  const needTriage = low.filter((r) => !r.has_ticket && !r.draft_status);
  const openTickets = tickets.filter((t) => t.status === 'open' || t.status === 'investigating');
  const pendingDrafts = drafts.filter((d) => d.status === 'pending_approval');
  const last30 = reviews.filter((r) => new Date(r.reviewed_at ?? r.created_at).getTime() > now - 30 * 864e5);
  const avg30 = last30.length ? (last30.reduce((s, r) => s + r.rating, 0) / last30.length).toFixed(2) : '—';
  const qaTotal = prec.reduce((s, p) => s + p.verified, 0), qaOk = prec.reduce((s, p) => s + p.correct, 0);

  return (
    <>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        <Kpi label={`Đánh giá cần xử lý (≤ ${maxRating}★)`} v={needTriage.length} hint={`${low.length} đánh giá tiêu cực · ${reviews.length} tổng`} tone={needTriage.length ? 'red' : 'default'} />
        <Kpi label="Ticket VOC đang mở" v={openTickets.length} hint={`${openTickets.filter((t) => t.priority === 'P0' || t.priority === 'P1').length} ưu tiên cao`} tone={openTickets.length ? 'amber' : 'default'} />
        <Kpi label="Phản hồi chờ duyệt" v={pendingDrafts.length} hint={`${drafts.filter((d) => d.status === 'sent').length} đã gửi`} />
        <Card className="p-4">
          <p className="text-xs text-gray-500">Rating TB 30 ngày · QA phân loại</p>
          <p className="text-2xl font-bold mt-1 text-gray-900">{avg30}★ <span className="text-base font-medium text-gray-500">· {qaTotal ? `${Math.round(100 * qaOk / qaTotal)}%` : '—'}</span></p>
          <p className="text-xs text-gray-500 mt-0.5">{last30.length} review · {qaTotal} mẫu đã QA</p>
          {canWrite && <button className={`${btn.ghost} px-0 mt-1`} disabled={busy} onClick={reclassify}>{busy ? 'Đang phân loại…' : 'Phân loại lại →'}</button>}
        </Card>
      </div>

      <div className="flex flex-wrap gap-2 mb-3 text-sm">
        {([['triage', `Đánh giá tiêu cực (${needTriage.length})`], ['topics', 'Chủ đề theo ASIN'], ['tickets', `Ticket (${openTickets.length})`], ['drafts', `Liên hệ khách hàng (${pendingDrafts.length})`], ['qa', 'QA phân loại']] as const).map(([k, l]) => (
          <button key={k} onClick={() => setTab(k)} className={`px-3 py-1.5 rounded-lg border ${tab === k ? 'bg-gray-900 text-white border-gray-900' : 'bg-white text-gray-700 border-gray-200 hover:bg-gray-50'}`}>{l}</button>
        ))}
      </div>

      {tab === 'triage' && (
        <div className={`grid gap-4 ${sel ? 'xl:grid-cols-3' : ''}`}>
          <Card className={sel ? 'xl:col-span-2' : ''}>
            {low.length === 0 ? <EmptyState title="Không có đánh giá tiêu cực (1–3★)" description="Nhập đánh giá từ Brand Registry → Customer Reviews qua trang Nhập dữ liệu." /> : (
              <Paged items={[...low].sort((a, b) => Number(a.has_ticket || !!a.draft_status) - Number(b.has_ticket || !!b.draft_status) || (b.severity ?? 0) - (a.severity ?? 0) || a.rating - b.rating)} page={LIMITS.listPage} label="đánh giá">{(visible) => (<ul className="divide-y divide-gray-100">
                {visible.map((r) => (
                  <li key={r.id} className={`px-5 py-3 cursor-pointer hover:bg-gray-50 ${sel?.id === r.id ? 'bg-indigo-50/50' : ''}`} onClick={() => setSel(r)}>
                    <div className="flex flex-wrap items-center gap-2">
                      <Stars n={r.rating} />
                      {r.severity === 3 && <Badge className="bg-red-600 text-white ring-red-700">Nghiêm trọng</Badge>}
                      {(r.topics ?? []).map((t) => <Badge key={t} className={TYPE_CLS[topicMap[t]?.type ?? 'other']}>{topicMap[t]?.label ?? (t === 'UNCLASSIFIED' ? 'Chưa phân loại' : t)}</Badge>)}
                      {r.has_ticket && <Badge className="bg-indigo-50 text-indigo-700 ring-indigo-600/20">Có ticket</Badge>}
                      {r.draft_status && <Badge className={DSTATUS[r.draft_status]?.cls ?? ''}>Liên hệ KH: {DSTATUS[r.draft_status]?.label}</Badge>}
                      {r.verified_purchase && <span className="text-[10px] uppercase text-gray-400">verified</span>}
                    </div>
                    <p className="text-sm font-medium text-gray-900 mt-1">{r.title ?? '(không tiêu đề)'}</p>
                    <p className="text-sm text-gray-600 line-clamp-2">{r.body}</p>
                    <p className="text-xs text-gray-500 mt-0.5"><span className="font-mono">{r.asin}</span> · {r.sku_title ?? '—'} · {new Date(r.reviewed_at ?? r.created_at).toLocaleDateString('vi-VN')}</p>
                  </li>
                ))}
              </ul>)}</Paged>
            )}
          </Card>
          {sel && <ReviewPanel review={sel} topics={topics} members={members} canWrite={canWrite} userId={user?.id ?? null} tenantId={tenant!.id} onClose={() => setSel(null)} onChanged={load} />}
        </div>
      )}

      {tab === 'topics' && <TopicsTab summary={summary} />}

      {tab === 'tickets' && <TicketsTab tickets={tickets} members={members} canWrite={canWrite} userId={user?.id ?? null} onChanged={load} />}

      {tab === 'drafts' && <DraftsTab drafts={drafts} reviews={reviews} canWrite={canWrite} userId={user?.id ?? null} membersCount={members.length} onChanged={load} />}

      {tab === 'qa' && <QaTab prec={prec} topicMap={topicMap} tenantId={tenant!.id} canWrite={canWrite} onChanged={load} />}
    </>
  );
}

/* ---------------- Review panel: classifications + ticket + draft ---------------- */
function ReviewPanel({ review: r, topics, members, canWrite, userId, tenantId, onClose, onChanged }: { review: Review; topics: Topic[]; members: Member[]; canWrite: boolean; userId: string | null; tenantId: string; onClose: () => void; onChanged: () => void }) {
  const [cls, setCls] = React.useState<Cls[]>([]);
  const [mode, setMode] = React.useState<'view' | 'ticket' | 'draft'>('view');
  const [tk, setTk] = React.useState({ type: 'defect', topic_code: '', priority: 'P2', title: '', description: '', assigned_to: '' });
  const [body, setBody] = React.useState('');
  const [check, setCheck] = React.useState<{ ok: boolean; violations: string[]; warnings: string[] } | null>(null);
  const [err, setErr] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState(false);
  const topicMap = Object.fromEntries(topics.map((t) => [t.code, t]));

  React.useEffect(() => {
    (async () => {
      const { data } = await supabase.from('review_classifications').select('*').eq('review_id', r.id).order('severity', { ascending: false });
      const c = (data ?? []) as Cls[]; setCls(c);
      const top = c[0]; const tp = top ? topicMap[top.topic_code] : undefined;
      setTk({ type: tp?.type && tp.type !== 'positive' ? tp.type : 'defect', topic_code: top?.topic_code ?? '', priority: top?.severity === 3 ? 'P1' : 'P2', title: `${tp?.label ?? 'Review sao thấp'} – ${r.asin}`, description: `Review ${r.rating}★ (${new Date(r.reviewed_at ?? r.created_at).toLocaleDateString('vi-VN')}): "${r.title ?? ''}" – ${r.body.slice(0, 300)}`, assigned_to: '' });
      setMode('view'); setBody(''); setCheck(null); setErr(null);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reset when review changes
  }, [r.id]);

  async function suggest() {
    const { data } = await supabase.rpc('suggest_response', { p_review: r.id });
    setBody(String(data ?? '')); setCheck(null);
  }
  async function runCheck(text: string) {
    const { data } = await supabase.rpc('check_response_policy', { t: tenantId, body: text });
    setCheck(data as { ok: boolean; violations: string[]; warnings: string[] });
  }
  async function createTicket() {
    setBusy(true); setErr(null);
    const { error } = await supabase.from('voc_tickets').insert({ tenant_id: tenantId, asin: r.asin, sku_id: r.sku_id, type: tk.type, topic_code: tk.topic_code || null, priority: tk.priority, title: tk.title, description: tk.description, review_ids: [r.id], assigned_to: tk.assigned_to || null });
    setBusy(false); if (error) setErr(error.message); else { setMode('view'); onChanged(); }
  }
  async function saveDraft(submit: boolean) {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.from('response_drafts').insert({ tenant_id: tenantId, review_id: r.id, body, channel: 'buyer_message', status: 'draft' }).select('id, policy_check').single();
    if (error) { setBusy(false); setErr(error.message); return; }
    if (submit) {
      const { error: e2 } = await supabase.from('response_drafts').update({ status: 'pending_approval' }).eq('id', data.id);
      if (e2) { setBusy(false); setErr(e2.message); setCheck(data.policy_check); return; }
    }
    setBusy(false); setMode('view'); onChanged();
  }
  async function verify(c: Cls, ok: boolean) {
    await supabase.from('review_classifications').update({ verified_ok: ok, verified_at: new Date().toISOString(), verified_by: userId }).eq('id', c.id);
    setCls(cls.map((x) => x.id === c.id ? { ...x, verified_ok: ok, verified_at: new Date().toISOString() } : x)); onChanged();
  }

  return (
    <Card className="self-start">
      <CardHeader title={`${r.rating}★ · ${r.asin}`} subtitle={r.sku_title ?? undefined} action={<button className={btn.ghost} onClick={onClose}>✕</button>} />
      <div className="p-4 space-y-3 text-sm">
        <div className="rounded-lg bg-gray-50 p-3"><p className="font-medium text-gray-900">{r.title}</p><p className="text-gray-700 mt-1 whitespace-pre-wrap">{r.body}</p></div>
        <div>
          <p className="text-xs font-medium text-gray-700 mb-1">Chủ đề phát hiện (theo từ khoá khớp)</p>
          <ul className="space-y-1">
            {cls.map((c) => (
              <li key={c.id} className="flex flex-wrap items-center gap-2 text-xs">
                <Badge className={TYPE_CLS[topicMap[c.topic_code]?.type ?? 'other']}>{topicMap[c.topic_code]?.label ?? (c.topic_code === 'UNCLASSIFIED' ? 'Chưa phân loại' : c.topic_code)}</Badge>
                <span className="text-gray-500">mức {c.severity} · tin cậy {Math.round(c.confidence * 100)}% · {c.method}{c.matched?.length ? ` · khớp: ${c.matched.join(', ')}` : ''}</span>
                {canWrite && (c.verified_at ? <span className={c.verified_ok ? 'text-emerald-700' : 'text-red-600'}>{c.verified_ok ? '✓ đúng' : '✗ sai'}</span> : <span className="flex gap-1"><button className="text-emerald-700 hover:underline" onClick={() => verify(c, true)}>đúng</button>·<button className="text-red-600 hover:underline" onClick={() => verify(c, false)}>sai</button></span>)}
              </li>
            ))}
          </ul>
        </div>
        {r.sku_id && <Link href={`/skus/${r.sku_id}`} className="text-xs text-indigo-600 hover:underline">Chi tiết ASIN →</Link>}

        {canWrite && mode === 'view' && (
          <div className="flex flex-wrap gap-2 pt-2 border-t border-gray-100">
            {!r.has_ticket && <button className={btn.primary} onClick={() => setMode('ticket')}>Mở ticket VOC</button>}
            {!r.draft_status && <button className={btn.secondary} onClick={() => { setMode('draft'); suggest(); }}>Soạn tin liên hệ khách hàng</button>}
          </div>
        )}
        {mode === 'ticket' && (
          <div className="space-y-2 pt-2 border-t border-gray-100">
            <p className="text-xs font-medium text-gray-700">Ticket VOC mới</p>
            <div className="grid grid-cols-2 gap-2">
              <select value={tk.type} onChange={(e) => setTk({ ...tk, type: e.target.value })} className={input}>{['defect', 'content', 'logistics', 'service', 'other'].map((t) => <option key={t} value={t}>{TYPE_LABEL[t]}</option>)}</select>
              <select value={tk.priority} onChange={(e) => setTk({ ...tk, priority: e.target.value })} className={input}>{['P0', 'P1', 'P2', 'P3'].map((p) => <option key={p}>{p}</option>)}</select>
              <select value={tk.topic_code} onChange={(e) => setTk({ ...tk, topic_code: e.target.value })} className={input}><option value="">— chủ đề —</option>{topics.filter((t) => t.type !== 'positive').map((t) => <option key={t.code} value={t.code}>{t.label}</option>)}</select>
              <select value={tk.assigned_to} onChange={(e) => setTk({ ...tk, assigned_to: e.target.value })} className={input}><option value="">— chưa gán —</option>{members.map((m) => <option key={m.user_id} value={m.user_id}>{m.user_id === userId ? 'Tôi' : `${m.role} · ${m.user_id.slice(0, 6)}`}</option>)}</select>
            </div>
            <input value={tk.title} onChange={(e) => setTk({ ...tk, title: e.target.value })} className={input} placeholder="Tiêu đề" />
            <textarea value={tk.description} onChange={(e) => setTk({ ...tk, description: e.target.value })} rows={3} className={input} />
            {err && <ErrorBox message={err} />}
            <div className="flex gap-2"><button className={btn.primary} disabled={busy || !tk.title.trim()} onClick={createTicket}>Tạo ticket</button><button className={btn.secondary} onClick={() => setMode('view')}>Huỷ</button></div>
          </div>
        )}
        {mode === 'draft' && (
          <div className="space-y-2 pt-2 border-t border-gray-100">
            <p className="text-xs font-medium text-gray-700">Tin liên hệ khách hàng (Brand Registry → Customer Reviews → Contact Customer, chỉ áp dụng review 1–3★) – người khác duyệt trước khi gửi</p>
            <textarea value={body} onChange={(e) => { setBody(e.target.value); setCheck(null); }} onBlur={() => body && runCheck(body)} rows={6} className={input} placeholder="Đang tạo gợi ý theo mẫu…" />
            <p className="text-[11px] text-gray-500">Theo Điều khoản Cộng đồng Amazon: không đề nghị sửa/gỡ đánh giá, không nhắc “5 sao”, không tặng quà/hoàn tiền đổi lấy đánh giá, không dẫn khách ra ngoài Amazon (link/SĐT/email). Hệ thống tự kiểm tra trước khi gửi duyệt.</p>
            {check && (
              <div className={`rounded-lg px-3 py-2 text-xs ${check.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>
                {check.ok ? 'Đạt kiểm tra chính sách Amazon.' : `Vi phạm: ${check.violations.join(', ')}`}{check.warnings?.length ? ` · Lưu ý: ${check.warnings.join('; ')}` : ''}
              </div>
            )}
            {err && <ErrorBox message={err} />}
            <div className="flex flex-wrap gap-2">
              <button className={btn.secondary} onClick={() => runCheck(body)} disabled={!body}>Kiểm tra</button>
              <button className={btn.secondary} onClick={() => saveDraft(false)} disabled={busy || !body}>Lưu nháp</button>
              <button className={btn.primary} onClick={() => saveDraft(true)} disabled={busy || !body || (check != null && !check.ok)}>Gửi duyệt</button>
              <button className={btn.ghost} onClick={() => setMode('view')}>Huỷ</button>
            </div>
          </div>
        )}
      </div>
    </Card>
  );
}

/* ---------------- Topics ---------------- */
function TopicsTab({ summary }: { summary: Summary[] }) {
  const [range, setRange] = React.useState<'reviews_30d' | 'reviews_90d' | 'reviews'>('reviews_90d');
  const byTopic = new Map<string, { label: string; type: string; n: number; asins: Set<string>; sumR: number }>();
  summary.forEach((s) => { const c = byTopic.get(s.topic_code) ?? { label: s.label, type: s.type, n: 0, asins: new Set(), sumR: 0 }; c.n += Number(s[range]); if (Number(s[range]) > 0) c.asins.add(s.asin); c.sumR += Number(s.avg_rating) * Number(s[range]); byTopic.set(s.topic_code, c); });
  const rows = [...byTopic.entries()].filter(([, c]) => c.n > 0).sort((a, b) => b[1].n - a[1].n);
  const maxN = rows[0]?.[1].n ?? 1;
  const byAsin = new Map<string, Summary[]>();
  summary.filter((s) => Number(s[range]) > 0).forEach((s) => byAsin.set(s.asin, [...(byAsin.get(s.asin) ?? []), s]));
  const positives = summary.filter((s) => s.type === 'positive' && Number(s[range]) > 0).sort((a, b) => Number(b[range]) - Number(a[range]));
  return (
    <div className="grid lg:grid-cols-2 gap-4">
      <Card className="lg:col-span-2 border-emerald-200">
        <CardHeader title="Điểm khách khen – dùng cho listing & quảng cáo" subtitle="Amazon đã bỏ bình luận công khai dưới đánh giá và không cho liên hệ người đánh giá 4–5★, nên giá trị của đánh giá tích cực nằm ở việc khai thác: đưa vào bullet points, A+ Content, ảnh, tiêu đề quảng cáo Sponsored Products." />
        {positives.length === 0 ? <p className="p-5 text-sm text-gray-500">Chưa có đánh giá 4–5★ được phân loại trong kỳ.</p> : (
          <div className="p-4 flex flex-wrap gap-2">
            {positives.map((s) => <Badge key={s.asin + s.topic_code} className={TYPE_CLS.positive}>{s.asin} · {Number(s[range])} đánh giá · {Number(s.avg_rating).toFixed(1)}★</Badge>)}
          </div>
        )}
      </Card>
      <Card>
        <CardHeader title="Chủ đề khách hàng nhắc đến" action={<select value={range} onChange={(e) => setRange(e.target.value as typeof range)} className="text-sm border border-gray-200 rounded-lg px-2 py-1"><option value="reviews_30d">30 ngày</option><option value="reviews_90d">90 ngày</option><option value="reviews">Tất cả</option></select>} />
        {rows.length === 0 ? <EmptyState title="Chưa có phân loại" /> : (
          <ul className="p-4 space-y-2">
            {rows.map(([code, c]) => (
              <li key={code}>
                <div className="flex justify-between text-sm"><span className="flex items-center gap-2"><Badge className={TYPE_CLS[c.type] ?? TYPE_CLS.other}>{TYPE_LABEL[c.type]}</Badge>{c.label}</span><span className="tabular-nums text-gray-600">{c.n} review · {c.asins.size} ASIN · {(c.sumR / c.n).toFixed(1)}★</span></div>
                <div className="h-1.5 bg-gray-100 rounded mt-1"><div className={`h-1.5 rounded ${c.type === 'positive' ? 'bg-emerald-500' : c.type === 'defect' ? 'bg-red-500' : 'bg-amber-500'}`} style={{ width: `${100 * c.n / maxN}%` }} /></div>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <Card>
        <CardHeader title="Theo ASIN" subtitle="Chủ đề nổi bật của từng ASIN – ⚠ = có mức nghiêm trọng" />
        {byAsin.size === 0 ? <EmptyState title="Chưa có dữ liệu" /> : (
          <ul className="divide-y divide-gray-100">
            {[...byAsin.entries()].sort((a, b) => b[1].reduce((s, x) => s + Number(x[range]), 0) - a[1].reduce((s, x) => s + Number(x[range]), 0)).map(([asin, list]) => (
              <li key={asin} className="px-4 py-3">
                <p className="font-mono text-xs text-gray-500">{asin}</p>
                <div className="flex flex-wrap gap-1.5 mt-1">
                  {list.sort((a, b) => Number(b[range]) - Number(a[range])).map((s) => <Badge key={s.topic_code} className={TYPE_CLS[s.type] ?? TYPE_CLS.other}>{s.label} · {Number(s[range])}{s.max_severity === 3 && s.type !== 'positive' ? ' ⚠' : ''}</Badge>)}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

/* ---------------- Tickets ---------------- */
function TicketsTab({ tickets, members, canWrite, userId, onChanged }: { tickets: Ticket[]; members: Member[]; canWrite: boolean; userId: string | null; onChanged: () => void }) {
  const [showClosed, setShowClosed] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  async function patch(id: string, p: Record<string, unknown>) { const { error } = await supabase.from('voc_tickets').update(p).eq('id', id); if (error) setErr(error.message); else onChanged(); }
  const list = tickets.filter((t) => showClosed || t.status === 'open' || t.status === 'investigating');
  return (
    <Card>
      <CardHeader title="Ticket VOC" subtitle="Chất lượng → QC/nhà cung cấp · Nội dung → tối ưu listing (bullet, ảnh, A+) · Fulfillment → đóng gói/FBA prep · Dịch vụ → CS" action={<label className="text-sm flex items-center gap-2"><input type="checkbox" checked={showClosed} onChange={(e) => setShowClosed(e.target.checked)} className="rounded" />Hiện đã đóng</label>} />
      {err && <div className="p-4"><ErrorBox message={err} /></div>}
      {list.length === 0 ? <EmptyState title="Không có ticket" description="Mở ticket từ tab Đánh giá tiêu cực." /> : (
        <Paged items={list} page={LIMITS.listPage} label="ticket">{(visible) => (<ul className="divide-y divide-gray-100">
          {visible.map((t) => (
            <li key={t.id} className="px-5 py-3 flex flex-wrap gap-3 items-start">
              <Badge className={t.priority === 'P0' || t.priority === 'P1' ? 'bg-red-50 text-red-700 ring-red-600/20' : 'bg-gray-100 text-gray-700 ring-gray-500/20'}>{t.priority}</Badge>
              <div className="flex-1 min-w-0">
                <div className="flex flex-wrap gap-2 items-center"><Badge className={TYPE_CLS[t.type]}>{TYPE_LABEL[t.type]}</Badge><Badge className={TSTATUS[t.status].cls}>{TSTATUS[t.status].label}</Badge><span className="font-mono text-xs text-gray-500">{t.asin}</span></div>
                <p className="text-sm font-medium text-gray-900 mt-0.5">{t.title}</p>
                {t.description && <p className="text-xs text-gray-600 line-clamp-2">{t.description}</p>}
                <p className="text-xs text-gray-500 mt-0.5">{t.review_ids.length} review · {new Date(t.created_at).toLocaleString('vi-VN')}{t.resolution_note && ` · ${t.resolution_note}`}</p>
              </div>
              {canWrite && (
                <div className="flex flex-wrap gap-2 items-center shrink-0">
                  <select value={t.assigned_to ?? ''} onChange={(e) => patch(t.id, { assigned_to: e.target.value || null })} className={`${input} w-32 text-xs`}><option value="">— chưa gán —</option>{members.map((m) => <option key={m.user_id} value={m.user_id}>{m.user_id === userId ? 'Tôi' : `${m.role} · ${m.user_id.slice(0, 6)}`}</option>)}</select>
                  <select value={t.status} onChange={(e) => { const s = e.target.value; if (s === 'resolved' || s === 'wont_fix') { const note = prompt('Ghi chú xử lý:'); if (note == null) return; patch(t.id, { status: s, resolution_note: note }); } else patch(t.id, { status: s }); }} className={`${input} w-32 text-xs`}>{Object.entries(TSTATUS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</select>
                </div>
              )}
            </li>
          ))}
        </ul>)}</Paged>
      )}
    </Card>
  );
}

/* ---------------- Drafts ---------------- */
function DraftsTab({ drafts, reviews, canWrite, userId, membersCount, onChanged }: { drafts: Draft[]; reviews: Review[]; canWrite: boolean; userId: string | null; membersCount: number; onChanged: () => void }) {
  const [err, setErr] = React.useState<string | null>(null);
  const rmap = Object.fromEntries(reviews.map((r) => [r.id, r]));
  async function patch(id: string, p: Record<string, unknown>) { setErr(null); const { error } = await supabase.from('response_drafts').update(p).eq('id', id); if (error) setErr(error.message); else onChanged(); }
  return (
    <Card>
      <CardHeader title="Liên hệ khách hàng" subtitle="Amazon chỉ cho liên hệ người đánh giá 1–3★ qua Brand Registry (mẫu Customer support / Courtesy refund). Mọi tin đều qua kiểm tra chính sách và người duyệt khác người soạn; gửi trong Seller Central rồi đánh dấu Đã gửi." />
      {err && <div className="p-4"><ErrorBox message={err} /></div>}
      {drafts.length === 0 ? <EmptyState title="Chưa có tin liên hệ" description="Soạn từ tab Đánh giá tiêu cực." /> : (
        <Paged items={drafts} page={LIMITS.listPage} label="tin">{(visible) => (<ul className="divide-y divide-gray-100">
          {visible.map((d) => { const r = rmap[d.review_id]; const own = d.created_by === userId; const pc = d.policy_check; return (
            <li key={d.id} className="px-5 py-4">
              <div className="flex flex-wrap items-center gap-2"><Badge className={DSTATUS[d.status].cls}>{DSTATUS[d.status].label}</Badge>{r && <><Stars n={r.rating} /><span className="font-mono text-xs text-gray-500">{r.asin}</span></>}{pc && <span className={`text-xs ${pc.ok ? 'text-emerald-700' : 'text-red-600'}`}>{pc.ok ? '✓ chính sách' : `✗ ${pc.violations.join(', ')}`}</span>}<span className="text-xs text-gray-400">{new Date(d.created_at).toLocaleString('vi-VN')}{own && ' · tôi soạn'}</span></div>
              {r && <p className="text-xs text-gray-500 mt-1 line-clamp-1">Review: {r.title ?? r.body}</p>}
              <p className="text-sm text-gray-800 mt-1 whitespace-pre-wrap bg-gray-50 rounded-lg p-3">{d.body}</p>
              {d.rejected_reason && <p className="text-xs text-red-600 mt-1">Lý do từ chối: {d.rejected_reason}</p>}
              {canWrite && (
                <div className="flex flex-wrap gap-2 mt-2">
                  {d.status === 'draft' && <button className={btn.primary} onClick={() => patch(d.id, { status: 'pending_approval' })}>Gửi duyệt</button>}
                  {d.status === 'pending_approval' && (!own || membersCount <= 1) && <><button className={btn.success} onClick={() => patch(d.id, { status: 'approved' })}>Duyệt</button><button className={btn.danger} onClick={() => { const reason = prompt('Lý do từ chối:'); if (reason) patch(d.id, { status: 'rejected', rejected_reason: reason }); }}>Từ chối</button></>}
                  {d.status === 'pending_approval' && own && membersCount > 1 && <span className="text-xs text-gray-500 self-center">Chờ người khác duyệt</span>}
                  {d.status === 'approved' && <><button className={btn.secondary} onClick={() => navigator.clipboard?.writeText(d.body)}>Sao chép</button><button className={btn.primary} onClick={() => patch(d.id, { status: 'sent' })}>Đã gửi trong Seller Central</button></>}
                  {d.status === 'rejected' && <button className={btn.secondary} onClick={() => patch(d.id, { status: 'draft' })}>Về nháp</button>}
                </div>
              )}
            </li>
          ); })}
        </ul>)}</Paged>
      )}
    </Card>
  );
}

/* ---------------- QA ---------------- */
function QaTab({ prec, topicMap, tenantId, canWrite, onChanged }: { prec: Prec[]; topicMap: Record<string, Topic>; tenantId: string; canWrite: boolean; onChanged: () => void }) {
  const [sample, setSample] = React.useState<(Cls & { raw_reviews: { rating: number; title: string | null; body: string; asin: string } })[]>([]);
  const [loading, setLoading] = React.useState(false);
  async function drawSample() {
    setLoading(true);
    const { data } = await supabase.from('review_classifications').select('*, raw_reviews(rating,title,body,asin)').eq('tenant_id', tenantId).neq('method', 'human').is('verified_at', null).limit(200);
    const arr = (data ?? []) as typeof sample; for (let i = arr.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [arr[i], arr[j]] = [arr[j], arr[i]]; }
    setSample(arr.slice(0, 10)); setLoading(false);
  }
  async function verify(c: Cls, ok: boolean) {
    const { data: { user } } = await supabase.auth.getUser();
    await supabase.from('review_classifications').update({ verified_ok: ok, verified_at: new Date().toISOString(), verified_by: user?.id ?? null }).eq('id', c.id);
    setSample(sample.filter((x) => x.id !== c.id)); onChanged();
  }
  const total = prec.reduce((s, p) => s + p.verified, 0), ok = prec.reduce((s, p) => s + p.correct, 0);
  return (
    <div className="grid lg:grid-cols-2 gap-4">
      <Card>
        <CardHeader title="Precision phân loại theo chủ đề" subtitle={`Gate tuần 9‑10: ${total} mẫu đã QA · tổng ${total ? Math.round(100 * ok / total) : '—'}%`} />
        <table className="w-full text-sm">
          <thead className="text-xs uppercase text-gray-500 bg-gray-50"><tr><th className="px-4 py-2 text-left">Chủ đề</th><th className="px-2 py-2 text-right">Gán</th><th className="px-2 py-2 text-right">Đã QA</th><th className="px-4 py-2 text-right">Precision</th></tr></thead>
          <tbody className="divide-y divide-gray-100">
            {prec.sort((a, b) => b.total - a.total).map((p) => <tr key={p.topic_code}><td className="px-4 py-2">{topicMap[p.topic_code]?.label ?? (p.topic_code === 'UNCLASSIFIED' ? 'Chưa phân loại' : p.topic_code)}</td><td className="px-2 py-2 text-right tabular-nums">{p.total}</td><td className="px-2 py-2 text-right tabular-nums">{p.verified}</td><td className={`px-4 py-2 text-right tabular-nums font-medium ${p.precision_pct == null ? 'text-gray-400' : p.precision_pct >= 80 ? 'text-emerald-700' : 'text-red-600'}`}>{p.precision_pct != null ? `${p.precision_pct}%` : '—'}</td></tr>)}
          </tbody>
        </table>
        <p className="px-4 py-3 text-xs text-gray-500 border-t border-gray-100">Phân loại dùng từ khoá (giải thích được, không gọi AI). Chủ đề precision thấp → chỉnh từ khoá trong bảng review_topics. Tin liên hệ được rà 0 từ ngữ vi phạm chính sách bởi trigger DB.</p>
      </Card>
      <Card>
        <CardHeader title="QA mẫu ngẫu nhiên" subtitle="Rút 10 phân loại chưa QA, đánh dấu đúng/sai" action={canWrite && <button className={btn.secondary} disabled={loading} onClick={drawSample}>{loading ? '…' : 'Rút mẫu'}</button>} />
        {sample.length === 0 ? <p className="p-5 text-sm text-gray-500">Bấm “Rút mẫu” để bắt đầu.</p> : (
          <ul className="divide-y divide-gray-100">
            {sample.map((c) => (
              <li key={c.id} className="px-4 py-3 text-sm">
                <div className="flex flex-wrap items-center gap-2"><Stars n={c.raw_reviews.rating} /><Badge className={TYPE_CLS[topicMap[c.topic_code]?.type ?? 'other']}>{topicMap[c.topic_code]?.label ?? c.topic_code}</Badge><span className="text-xs text-gray-500">khớp: {c.matched?.join(', ') || '—'}</span></div>
                <p className="text-gray-700 mt-1 line-clamp-3">{c.raw_reviews.title ? `${c.raw_reviews.title} – ` : ''}{c.raw_reviews.body}</p>
                <div className="flex gap-2 mt-2"><button className={btn.success} onClick={() => verify(c, true)}>Đúng</button><button className={btn.danger} onClick={() => verify(c, false)}>Sai</button></div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function Kpi({ label, v, hint, tone }: { label: string; v: React.ReactNode; hint?: string; tone?: 'red' | 'amber' | 'default' }) {
  return <Card className="p-4"><p className="text-xs text-gray-500">{label}</p><p className={`text-2xl font-bold mt-1 ${tone === 'red' ? 'text-red-600' : tone === 'amber' ? 'text-amber-700' : 'text-gray-900'}`}>{v}</p>{hint && <p className="text-xs text-gray-500 mt-0.5">{hint}</p>}</Card>;
}
