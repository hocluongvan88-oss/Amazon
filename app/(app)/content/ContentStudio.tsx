'use client';

import React from 'react';
import { CvrBeforeAfterChart, type CvrPoint } from '@/components/charts';
import AplusEditor, { AplusPreview } from '@/components/AplusEditor';
import { moduleToText, handoffMarkdown, upgradeLegacyModule, type ModuleData } from '@/lib/aplus';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { LIMITS } from '@/lib/limits';
import { Paged } from '@/components/ShowMore';
import { Card, CardHeader, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

// ---------- types ----------
type PubRec = { id: string; content_version_id: string; kind: 'publish' | 'rollback'; channel: string; performed_at: string; evidence_url: string | null; evidence_note: string | null; verify_status: string };
type Audit = {
  sku_id: string; asin: string; title: string; facts_verified: number; facts_proposed: number;
  has_title: boolean; has_bullets: boolean; has_description: boolean; has_backend: boolean; has_aplus: boolean;
  cvr_30d: number | null; sessions_30d: number | null; cvr_median: number | null; neg_reviews_90d: number;
  opportunity_score: number; reasons: string[];
};
type Fact = {
  id: string; key: string; value: string; unit: string | null; source_type: string; source_ref: string | null;
  status: string; proposed_by: string | null; verified_at: string | null; reject_reason: string | null; note: string | null;
};
type Kind = 'title' | 'bullets' | 'description' | 'backend_keywords' | 'aplus';
type Issue = { code: string; severity: 'block' | 'warn'; msg: string };
type Compliance = { ok: boolean; blocks: number; warns: number; issues: Issue[] } | null;
type Version = {
  id: string; kind: Kind; version: number; body: Record<string, unknown>; claims: { text: string; fact_id: string | null }[];
  brief: string | null; origin: string; status: string; compliance: Compliance; compliance_override_reason: string | null;
  created_by: string | null; qa_by: string | null; brand_by: string | null; published_at: string | null;
  reject_reason: string | null; rollback_reason: string | null; created_at: string; updated_at: string;
};
type Readiness = { has_brand_approver: boolean; has_delegated_brand_approver: boolean; awaiting_brand: number; awaiting_qa: number; ready_to_publish: number };

const KIND_LABEL: Record<Kind, string> = { title: 'Title', bullets: 'Bullets', description: 'Mô tả', backend_keywords: 'Backend keywords', aplus: 'A+ Content' };
const KINDS = Object.keys(KIND_LABEL) as Kind[];
const STATUS: Record<string, { label: string; cls: string }> = {
  draft: { label: 'Nháp', cls: 'bg-gray-100 text-gray-700' },
  qa_review: { label: 'Chờ QA', cls: 'bg-amber-50 text-amber-800' },
  qa_passed: { label: 'QA đạt', cls: 'bg-sky-50 text-sky-800' },
  qa_blocked: { label: 'QA chặn', cls: 'bg-red-50 text-red-700' },
  awaiting_brand_approval: { label: 'Chờ brand duyệt', cls: 'bg-violet-50 text-violet-800' },
  approved: { label: 'Đã duyệt', cls: 'bg-emerald-50 text-emerald-700' },
  published: { label: 'Đã publish', cls: 'bg-emerald-600 text-white' },
  rejected: { label: 'Từ chối', cls: 'bg-red-50 text-red-700' },
  rolled_back: { label: 'Đã rollback', cls: 'bg-orange-50 text-orange-800' },
  superseded: { label: 'Bị thay thế', cls: 'bg-gray-100 text-gray-500' },
};
const SOURCE_LABEL: Record<string, string> = { manual: 'Nhập tay', document: 'Tài liệu', csv: 'CSV', sp_api: 'SP‑API', lab_test: 'Kết quả kiểm nghiệm', supplier: 'Nhà cung cấp', brand_guideline: 'Brand guideline' };

// ---------- helpers ----------
function emptyBody(kind: Kind): Record<string, unknown> {
  if (kind === 'bullets') return { items: [''] };
  if (kind === 'aplus') return { modules: [] };
  return { text: '' };
}
function bodyToText(kind: Kind, body: Record<string, unknown>): string {
  if (kind === 'bullets') return ((body.items as string[]) ?? []).map((b, i) => `${i + 1}. ${b}`).join('\n');
  if (kind === 'aplus') return ((body.modules as ModuleData[]) ?? []).map((m, i) => moduleToText(upgradeLegacyModule(m as Record<string, unknown>), i)).join('\n\n');
  return String(body.text ?? '');
}
/** Diff theo dòng đơn giản (LCS) */
function diffLines(a: string, b: string): { t: ' ' | '+' | '-'; s: string }[] {
  const A = a.split('\n'), B = b.split('\n');
  const m = A.length, n = B.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--) for (let j = n - 1; j >= 0; j--) dp[i][j] = A[i] === B[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const out: { t: ' ' | '+' | '-'; s: string }[] = [];
  let i = 0, j = 0;
  while (i < m && j < n) {
    if (A[i] === B[j]) { out.push({ t: ' ', s: A[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push({ t: '-', s: A[i] }); i++; }
    else { out.push({ t: '+', s: B[j] }); j++; }
  }
  while (i < m) out.push({ t: '-', s: A[i++] });
  while (j < n) out.push({ t: '+', s: B[j++] });
  return out;
}

// ============================================================
export default function ContentStudio() {
  const { tenant, can, user } = useTenant();
  const [audit, setAudit] = React.useState<Audit[]>([]);
  const [ready, setReady] = React.useState<Readiness | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [sel, setSel] = React.useState<Audit | null>(null);
  const [q, setQ] = React.useState('');

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [a, r] = await Promise.all([
      supabase.from('v_listing_audit').select('*').eq('tenant_id', tenant.id).order('opportunity_score', { ascending: false }).limit(LIMITS.maxFetch),
      supabase.from('v_content_readiness').select('*').eq('tenant_id', tenant.id).maybeSingle(),
    ]);
    if (a.error) setError(a.error.message); else { setError(null); setAudit((a.data ?? []) as Audit[]); }
    setReady((r.data as Readiness) ?? null);
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error.includes('v_listing_audit') ? 'Chưa chạy migration 013_content_studio.sql' : error} />;

  const list = audit.filter((s) => !q || s.asin.toLowerCase().includes(q.toLowerCase()) || s.title.toLowerCase().includes(q.toLowerCase()));
  const brandOk = ready?.has_brand_approver || ready?.has_delegated_brand_approver;

  return (
    <div className="space-y-6">
      {!brandOk && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <b>Chưa có Brand Approver trong tenant.</b> Content sẽ dừng ở <i>Chờ brand duyệt</i> và không thể publish. Mời người của khách hàng (Cài đặt → Thành viên) hoặc nhận uỷ quyền có thời hạn.
        </div>
      )}
      {ready && (
        <div className="grid grid-cols-3 gap-3 text-sm">
          <Card className="p-4"><p className="text-xs text-gray-500">Chờ QA</p><p className="text-2xl font-semibold">{ready.awaiting_qa}</p></Card>
          <Card className="p-4"><p className="text-xs text-gray-500">Chờ brand duyệt</p><p className="text-2xl font-semibold">{ready.awaiting_brand}</p></Card>
          <Card className="p-4"><p className="text-xs text-gray-500">Đã duyệt, chờ publish</p><p className="text-2xl font-semibold">{ready.ready_to_publish}</p></Card>
        </div>
      )}

      <div className="grid lg:grid-cols-5 gap-6">
        <Card className="lg:col-span-2">
          <CardHeader title="Listing audit" subtitle="Cơ hội content theo SKU (facts · bullets · A+ · CVR · review tiêu cực)" />
          <div className="px-4 pt-3"><input value={q} onChange={(e) => setQ(e.target.value)} className={input} placeholder="Tìm ASIN / tên" /></div>
          {list.length === 0 ? <EmptyState title="Chưa có SKU" /> : (
            <Paged items={list} page={LIMITS.listPage} label="SKU">{(visible) => (
              <ul className="divide-y divide-gray-100 mt-2">
                {visible.map((s) => (
                  <li key={s.sku_id}>
                    <button onClick={() => setSel(s)} className={`w-full text-left px-4 py-3 hover:bg-gray-50 ${sel?.sku_id === s.sku_id ? 'bg-indigo-50' : ''}`}>
                      <div className="flex items-center gap-2">
                        <span className={`text-xs font-semibold px-1.5 py-0.5 rounded ${s.opportunity_score >= 50 ? 'bg-orange-100 text-orange-800' : s.opportunity_score >= 25 ? 'bg-amber-50 text-amber-800' : 'bg-emerald-50 text-emerald-700'}`}>{s.opportunity_score}</span>
                        <span className="font-mono text-sm">{s.asin}</span>
                        <span className="text-xs text-gray-500 truncate flex-1">{s.title}</span>
                      </div>
                      <div className="mt-1 flex flex-wrap gap-1 text-[11px] text-gray-500">
                        <span>{s.facts_verified} fact ✓</span>
                        {s.cvr_30d != null && <span>· CVR {(s.cvr_30d * 100).toFixed(1)}%</span>}
                        {KINDS.map((k) => <span key={k} className={s[`has_${k === 'backend_keywords' ? 'backend' : k}` as keyof Audit] ? 'text-emerald-600' : 'text-gray-300'}>· {KIND_LABEL[k]}</span>)}
                      </div>
                    </button>
                  </li>
                ))}
              </ul>
            )}</Paged>
          )}
        </Card>

        <div className="lg:col-span-3 space-y-6">
          {!sel ? <Card><EmptyState title="Chọn một SKU" description="Bên trái: điểm cơ hội càng cao càng nên làm content trước." /></Card> : (
            <SkuStudio key={sel.sku_id} sku={sel} can={can} userId={user?.id ?? null} tenantId={tenant!.id} brandOk={!!brandOk} onChanged={load} />
          )}
        </div>
      </div>
    </div>
  );
}

// ============================================================
function SkuStudio({ sku, can, userId, tenantId, brandOk, onChanged }: { sku: Audit; can: (p: string) => boolean; userId: string | null; tenantId: string; brandOk: boolean; onChanged: () => void }) {
  const [facts, setFacts] = React.useState<Fact[]>([]);
  const [versions, setVersions] = React.useState<Version[]>([]);
  const [tab, setTab] = React.useState<'facts' | Kind>('facts');
  const [error, setError] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);

  const load = React.useCallback(async () => {
    const [f, v] = await Promise.all([
      supabase.from('product_facts').select('*').eq('sku_id', sku.sku_id).order('status').order('key').limit(LIMITS.detailItems * 4),
      supabase.from('content_versions').select('*').eq('sku_id', sku.sku_id).order('kind').order('version', { ascending: false }).limit(LIMITS.detailItems * 4),
    ]);
    if (f.error) setError(f.error.message); else setFacts((f.data ?? []) as Fact[]);
    if (v.error) setError(v.error.message); else setVersions((v.data ?? []) as Version[]);
    setLoading(false);
  }, [sku.sku_id]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on sku change
    void load();
  }, [load]);

  const refresh = () => { load(); onChanged(); };
  if (loading) return <Spinner />;

  const verified = facts.filter((f) => f.status === 'verified');
  return (
    <>
      <Card>
        <div className="px-5 py-4 border-b border-gray-100">
          <p className="font-mono text-sm text-gray-500">{sku.asin}</p>
          <h2 className="text-lg font-semibold text-gray-900">{sku.title}</h2>
          {sku.reasons?.length > 0 && <ul className="mt-2 text-sm text-gray-700 list-disc pl-5 space-y-0.5">{sku.reasons.map((r) => <li key={r}>{r}</li>)}</ul>}
        </div>
        <div className="px-5 flex gap-1 overflow-x-auto border-b border-gray-100">
          {(['facts', ...KINDS] as const).map((k) => {
            const n = k === 'facts' ? `${verified.length}/${facts.length}` : versions.filter((v) => v.kind === k).length;
            return <button key={k} onClick={() => setTab(k)} className={`px-3 py-2 text-sm whitespace-nowrap border-b-2 ${tab === k ? 'border-indigo-600 text-indigo-700 font-medium' : 'border-transparent text-gray-600'}`}>{k === 'facts' ? 'Product Facts' : KIND_LABEL[k]} <span className="text-xs text-gray-400">({n})</span></button>;
          })}
        </div>
        {error && <div className="p-4"><ErrorBox message={error} /></div>}
        {tab === 'facts'
          ? <FactsPanel facts={facts} skuId={sku.sku_id} tenantId={tenantId} can={can} userId={userId} onChanged={refresh} onError={setError} />
          : <VersionsPanel kind={tab} versions={versions.filter((v) => v.kind === tab)} facts={verified} skuId={sku.sku_id} skuAsin={sku.asin} skuTitle={sku.title} tenantId={tenantId} can={can} userId={userId} brandOk={brandOk} onChanged={refresh} onError={setError} />}
      </Card>
    </>
  );
}

// ============================================================
function FactsPanel({ facts, skuId, tenantId, can, userId, onChanged, onError }: { facts: Fact[]; skuId: string; tenantId: string; can: (p: string) => boolean; userId: string | null; onChanged: () => void; onError: (m: string | null) => void }) {
  const [f, setF] = React.useState({ key: '', value: '', unit: '', source_type: 'document', source_ref: '', note: '' });
  const [busy, setBusy] = React.useState(false);
  const [rejectId, setRejectId] = React.useState<string | null>(null);
  const [reason, setReason] = React.useState('');

  async function propose(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); onError(null);
    const { error } = await supabase.from('product_facts').insert({ tenant_id: tenantId, sku_id: skuId, key: f.key.trim(), value: f.value.trim(), unit: f.unit || null, source_type: f.source_type, source_ref: f.source_ref || null, note: f.note || null });
    setBusy(false);
    if (error) onError(error.message); else { setF({ key: '', value: '', unit: '', source_type: 'document', source_ref: '', note: '' }); onChanged(); }
  }
  async function setStatus(id: string, status: string, reject_reason?: string) {
    onError(null);
    const { error } = await supabase.from('product_facts').update({ status, ...(reject_reason ? { reject_reason } : {}) }).eq('id', id);
    if (error) onError(error.message); else { setRejectId(null); setReason(''); onChanged(); }
  }

  const groups: [string, Fact[]][] = [['verified', []], ['proposed', []], ['rejected', []], ['retired', []]];
  facts.forEach((x) => groups.find(([s]) => s === x.status)?.[1].push(x));
  const GL: Record<string, string> = { verified: 'Đã xác minh', proposed: 'Chờ xác minh', rejected: 'Từ chối', retired: 'Đã thay thế' };

  return (
    <div className="p-5 space-y-5">
      <p className="text-xs text-gray-500">Mọi claim trong content phải trỏ về một fact <b>đã xác minh</b>. Người đề xuất không tự xác minh. Fact đã xác minh không sửa được — tạo fact mới để thay thế.</p>
      {groups.filter(([, arr]) => arr.length).map(([s, arr]) => (
        <div key={s}>
          <p className="text-xs font-semibold uppercase tracking-wide text-gray-500 mb-1">{GL[s]} ({arr.length})</p>
          <ul className="divide-y divide-gray-100 border border-gray-100 rounded-lg">
            {arr.map((x) => (
              <li key={x.id} className="px-3 py-2 text-sm flex flex-wrap items-center gap-2">
                <span className="font-mono text-xs bg-gray-100 px-1.5 py-0.5 rounded">{x.key}</span>
                <span className="font-medium">{x.value}{x.unit ? ` ${x.unit}` : ''}</span>
                <span className="text-xs text-gray-500">· {SOURCE_LABEL[x.source_type] ?? x.source_type}{x.source_ref ? ` · ${x.source_ref}` : ''}</span>
                {x.reject_reason && <span className="text-xs text-red-600">· {x.reject_reason}</span>}
                <span className="flex-1" />
                {s === 'proposed' && can('facts.approve') && (rejectId === x.id ? (
                  <>
                    <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${input} w-48`} placeholder="Lý do từ chối" />
                    <button className={btn.danger} disabled={!reason.trim()} onClick={() => setStatus(x.id, 'rejected', reason.trim())}>Từ chối</button>
                    <button className={btn.ghost} onClick={() => setRejectId(null)}>Huỷ</button>
                  </>
                ) : (
                  <>
                    <button className={btn.success} disabled={x.proposed_by === userId && !can('policy.override')} title={x.proposed_by === userId ? 'Bạn là người đề xuất' : ''} onClick={() => setStatus(x.id, 'verified')}>✓ Xác minh</button>
                    <button className={btn.secondary} onClick={() => setRejectId(x.id)}>Từ chối…</button>
                  </>
                ))}
                {s === 'verified' && can('facts.approve') && <button className={btn.ghost} onClick={() => setStatus(x.id, 'retired')}>Thu hồi</button>}
              </li>
            ))}
          </ul>
        </div>
      ))}
      {facts.length === 0 && <EmptyState title="Chưa có Product Fact" description="Thêm các thuộc tính có bằng chứng: chất liệu, dung tích, chứng nhận, bảo hành…" />}

      {can('facts.propose') && (
        <form onSubmit={propose} className="grid sm:grid-cols-2 gap-2 border-t border-gray-100 pt-4">
          <p className="sm:col-span-2 text-sm font-medium">Đề xuất fact mới</p>
          <input required value={f.key} onChange={(e) => setF({ ...f, key: e.target.value })} className={input} placeholder="key (vd: material, capacity, warranty_months)" />
          <input required value={f.value} onChange={(e) => setF({ ...f, value: e.target.value })} className={input} placeholder="giá trị (vd: Tritan BPA‑free, 750, 24)" />
          <input value={f.unit} onChange={(e) => setF({ ...f, unit: e.target.value })} className={input} placeholder="đơn vị (ml, months, %…) – tuỳ chọn" />
          <select value={f.source_type} onChange={(e) => setF({ ...f, source_type: e.target.value })} className={input}>
            {Object.entries(SOURCE_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select>
          <input value={f.source_ref} onChange={(e) => setF({ ...f, source_ref: e.target.value })} className={`${input} sm:col-span-2`} placeholder="Bằng chứng: link tài liệu / mã chứng nhận / tên file (bắt buộc trừ khi Nhập tay)" />
          <input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} className={`${input} sm:col-span-2`} placeholder="Ghi chú" />
          <div className="sm:col-span-2"><button className={btn.primary} disabled={busy}>{busy ? 'Đang gửi…' : 'Đề xuất'}</button></div>
        </form>
      )}
    </div>
  );
}

// ============================================================
function VersionsPanel({ kind, versions, facts, skuId, skuAsin, skuTitle, tenantId, can, userId, brandOk, onChanged, onError }: {
  kind: Kind; versions: Version[]; facts: Fact[]; skuId: string; skuAsin: string; skuTitle: string; tenantId: string; can: (p: string) => boolean; userId: string | null; brandOk: boolean; onChanged: () => void; onError: (m: string | null) => void;
}) {
  const [editing, setEditing] = React.useState<Version | 'new' | null>(null);
  const [compare, setCompare] = React.useState<Version | null>(null);
  const [impact, setImpact] = React.useState<Record<string, unknown> | null>(null);
  const [reasonFor, setReasonFor] = React.useState<{ id: string; status: string; field: string; title: string } | null>(null);
  const [reason, setReason] = React.useState('');
  const [premium, setPremium] = React.useState(false);
  const [pubFor, setPubFor] = React.useState<string | null>(null);
  const [pubUrl, setPubUrl] = React.useState('');
  const [pubNote, setPubNote] = React.useState('');
  const [pubRecs, setPubRecs] = React.useState<Record<string, PubRec[]>>({});
  React.useEffect(() => {
    const ids = versions.filter((v) => v.status === 'published' || v.status === 'rolled_back' || v.status === 'superseded').map((v) => v.id);
    if (ids.length === 0) return;
    (async () => {
      const { data } = await supabase.from('publish_records').select('id, content_version_id, kind, channel, performed_at, evidence_url, evidence_note, verify_status').in('content_version_id', ids).order('performed_at', { ascending: false }).limit(200);
      const m: Record<string, PubRec[]> = {};
      for (const r of (data ?? []) as PubRec[]) (m[r.content_version_id] ||= []).push(r);
      setPubRecs(m);
    })();
  }, [versions]);
  async function recordPublish(v: Version) {
    onError(null);
    const { error } = await supabase.rpc('record_publish', { p_version: v.id, p_evidence_url: pubUrl.trim() || null, p_evidence_note: pubNote.trim() || null });
    if (error) onError(error.message); else { setPubFor(null); setPubUrl(''); setPubNote(''); onChanged(); }
  }
  async function recordRollback(v: Version, why: string) {
    onError(null);
    const { error } = await supabase.rpc('record_rollback', { p_version: v.id, p_reason: why });
    if (error) onError(error.message); else { setReasonFor(null); setReason(''); onChanged(); }
  }
  const [prevOf, setPrevOf] = React.useState<{ id: string; mobile: boolean } | null>(null);
  React.useEffect(() => {
    if (kind !== 'aplus') return;
    (async () => { const { data } = await supabase.from('policy_register').select('aplus_premium_enabled').eq('tenant_id', tenantId).maybeSingle(); setPremium(Boolean((data as { aplus_premium_enabled?: boolean } | null)?.aplus_premium_enabled)); })();
  }, [kind, tenantId]);
  function downloadHandoff(v: Version) {
    const md = handoffMarkdown(skuAsin, skuTitle, (v.body.modules as ModuleData[]) ?? [], v.version);
    const blob = new Blob([md], { type: 'text/markdown;charset=utf-8' }); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `aplus-${skuAsin}-v${v.version}.md`; a.click(); URL.revokeObjectURL(a.href);
  }
  const published = versions.find((v) => v.status === 'published');

  async function transition(v: Version, status: string, extra: Record<string, unknown> = {}) {
    onError(null);
    const { error } = await supabase.from('content_versions').update({ status, ...extra }).eq('id', v.id);
    if (error) onError(error.message); else { setReasonFor(null); setReason(''); onChanged(); }
  }
  async function showImpact(v: Version) {
    const { data, error } = await supabase.rpc('content_impact', { p_version: v.id, p_days: 14 });
    if (error) onError(error.message); else setImpact(data as Record<string, unknown>);
  }

  return (
    <div className="p-5 space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-sm text-gray-600 flex-1">
          {published ? <>Đang publish: <b>v{published.version}</b> ({new Date(published.published_at!).toLocaleDateString('vi-VN')})</> : 'Chưa có bản nào được ghi nhận publish.'}
        </p>
        {can('content.draft') && <button className={btn.primary} onClick={() => setEditing('new')}>+ Draft mới</button>}
      </div>

      {editing && (
        <Editor kind={kind} base={editing === 'new' ? (published ?? versions[0] ?? null) : editing} isNew={editing === 'new'} facts={facts} skuId={skuId} tenantId={tenantId} premium={premium}
          onClose={() => setEditing(null)} onSaved={() => { setEditing(null); onChanged(); }} onError={onError} />
      )}

      {versions.length === 0 ? <EmptyState title="Chưa có version" /> : (
        <ul className="space-y-3">
          {versions.map((v) => {
            const st = STATUS[v.status] ?? { label: v.status, cls: 'bg-gray-100' };
            const mine = v.created_by === userId;
            const ov = can('policy.override');
            const c = v.compliance;
            return (
              <li key={v.id} className="border border-gray-200 rounded-lg">
                <div className="px-4 py-3 flex flex-wrap items-center gap-2">
                  <span className="font-semibold">v{v.version}</span>
                  <span className={`text-xs px-2 py-0.5 rounded-md font-medium ${st.cls}`}>{st.label}</span>
                  {v.origin !== 'human' && <Badge className="bg-gray-50 text-gray-600 ring-gray-500/20">{v.origin}</Badge>}
                  {c && <span className={`text-xs px-2 py-0.5 rounded-md ${c.ok ? 'bg-emerald-50 text-emerald-700' : 'bg-red-50 text-red-700'}`}>Gate: {c.ok ? 'đạt' : `${c.blocks} chặn`}{c.warns ? ` · ${c.warns} cảnh báo` : ''}</span>}
                  <span className="text-xs text-gray-400">{new Date(v.updated_at).toLocaleString('vi-VN')}</span>
                  <span className="flex-1" />
                  {published && published.id !== v.id && <button className={btn.ghost} onClick={() => setCompare(compare?.id === v.id ? null : v)}>{compare?.id === v.id ? 'Đóng diff' : 'So với bản publish'}</button>}
                  {v.published_at && <button className={btn.ghost} onClick={() => showImpact(v)}>Đo CVR</button>}
                </div>
                {kind === 'aplus' && (
                  <div className="px-4 pb-2 flex flex-wrap gap-2 text-xs">
                    <button className={btn.ghost} onClick={() => setPrevOf(prevOf?.id === v.id && !prevOf.mobile ? null : { id: v.id, mobile: false })}>Preview desktop</button>
                    <button className={btn.ghost} onClick={() => setPrevOf(prevOf?.id === v.id && prevOf.mobile ? null : { id: v.id, mobile: true })}>Preview mobile</button>
                    {(v.status === 'approved' || v.status === 'published') && <button className={btn.secondary} onClick={() => downloadHandoff(v)}>⇩ Gói bàn giao Seller Central (.md)</button>}
                  </div>
                )}
                {prevOf?.id === v.id ? <div className="px-4 pb-3"><AplusPreview modules={(v.body.modules as ModuleData[]) ?? []} mobile={prevOf.mobile} /></div>
                  : <pre className="px-4 pb-3 text-sm whitespace-pre-wrap font-sans text-gray-800">{bodyToText(kind, v.body)}</pre>}
                {v.claims?.length > 0 && (
                  <div className="px-4 pb-3 flex flex-wrap gap-1">
                    {v.claims.map((cl, i) => { const f = facts.find((x) => x.id === cl.fact_id); return <span key={i} className={`text-xs px-2 py-0.5 rounded-full ${f ? 'bg-emerald-50 text-emerald-700' : 'bg-red-50 text-red-700'}`}>{cl.text}{f ? ` → ${f.key}` : ' → thiếu fact'}</span>; })}
                  </div>
                )}
                {c && c.issues.length > 0 && (
                  <ul className="px-4 pb-3 text-xs space-y-0.5">
                    {c.issues.map((is, i) => <li key={i} className={is.severity === 'block' ? 'text-red-700' : 'text-amber-700'}>{is.severity === 'block' ? '⛔' : '⚠'} {is.msg}</li>)}
                  </ul>
                )}
                {(v.reject_reason || v.rollback_reason || v.compliance_override_reason) && (
                  <p className="px-4 pb-3 text-xs text-gray-600">{v.reject_reason && <>Lý do: {v.reject_reason} </>}{v.rollback_reason && <>Rollback: {v.rollback_reason} </>}{v.compliance_override_reason && <>Override gate: {v.compliance_override_reason}</>}</p>
                )}
                {compare?.id === v.id && published && (
                  <div className="mx-4 mb-3 rounded-md border border-gray-200 bg-gray-50 text-xs font-mono overflow-x-auto">
                    {diffLines(bodyToText(kind, published.body), bodyToText(kind, v.body)).map((d, i) => (
                      <div key={i} className={`px-2 whitespace-pre-wrap ${d.t === '+' ? 'bg-emerald-50 text-emerald-800' : d.t === '-' ? 'bg-red-50 text-red-800 line-through' : 'text-gray-600'}`}>{d.t} {d.s}</div>
                    ))}
                  </div>
                )}

                {/* actions */}
                <div className="px-4 py-2 border-t border-gray-100 flex flex-wrap gap-2 items-center">
                  {['draft', 'qa_blocked', 'rejected'].includes(v.status) && can('content.draft') && <>
                    <button className={btn.secondary} onClick={() => setEditing(v)}>Sửa</button>
                    <button className={btn.primary} disabled={!!c && !c.ok && !ov} title={c && !c.ok ? (ov ? 'Gate chặn – sẽ hỏi lý do override' : 'Gate chặn – sửa nội dung trước') : ''}
                      onClick={() => (c && !c.ok ? setReasonFor({ id: v.id, status: 'qa_review', field: 'compliance_override_reason', title: 'Lý do override Compliance Gate' }) : transition(v, 'qa_review'))}>Gửi QA</button>
                  </>}
                  {v.status === 'qa_review' && can('content.qa_approve') && <>
                    <button className={btn.success} disabled={mine && !ov} title={mine ? 'Bạn là người soạn' : ''} onClick={() => transition(v, 'qa_passed')}>✓ QA đạt</button>
                    <button className={btn.danger} onClick={() => setReasonFor({ id: v.id, status: 'qa_blocked', field: 'reject_reason', title: 'Lý do QA chặn' })}>QA chặn…</button>
                  </>}
                  {v.status === 'qa_passed' && (can('content.qa_approve') || can('content.draft')) && (
                    <button className={btn.primary} onClick={() => transition(v, 'awaiting_brand_approval')}>Gửi brand duyệt</button>
                  )}
                  {v.status === 'awaiting_brand_approval' && (can('content.brand_approve') ? <>
                    <button className={btn.success} disabled={(mine || v.qa_by === userId) && !ov} onClick={() => transition(v, 'approved')}>✓ Brand duyệt</button>
                    <button className={btn.danger} onClick={() => setReasonFor({ id: v.id, status: 'rejected', field: 'reject_reason', title: 'Lý do từ chối' })}>Từ chối…</button>
                  </> : <span className="text-xs text-gray-500">{brandOk ? 'Chờ Brand Approver.' : 'Tenant chưa có Brand Approver – content dừng tại đây.'}</span>)}
                  {v.status === 'approved' && can('content.publish') && (
                    <button className={btn.success} onClick={() => setPubFor(pubFor === v.id ? null : v.id)}>Ghi nhận đã publish (kèm bằng chứng)…</button>
                  )}
                  {v.status === 'published' && can('content.publish') && (
                    <button className={btn.secondary} onClick={() => setReasonFor({ id: v.id, status: 'rolled_back', field: 'rollback_reason', title: 'Lý do rollback (bạn ĐÃ khôi phục bản cũ trên Seller Central)' })}>Rollback…</button>
                  )}
                  {v.status === 'rejected' && can('content.draft') && <button className={btn.ghost} onClick={() => transition(v, 'draft')}>Mở lại</button>}
                </div>
                {reasonFor?.id === v.id && (
                  <div className="px-4 pb-3 flex flex-wrap gap-2 items-center">
                    <span className="text-sm">{reasonFor.title}:</span>
                    <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${input} flex-1 min-w-60`} autoFocus />
                    <button className={btn.primary} disabled={reason.trim().length < 3} onClick={() => reasonFor.status === 'rolled_back' ? recordRollback(v, reason.trim()) : transition(v, reasonFor.status, { [reasonFor.field]: reason.trim() })}>Xác nhận</button>
                    <button className={btn.ghost} onClick={() => setReasonFor(null)}>Huỷ</button>
                  </div>
                )}
                {pubFor === v.id && (
                  <div className="px-4 pb-3 space-y-2 text-sm">
                    <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1">Hệ thống KHÔNG tự đẩy lên Amazon. Chỉ ghi nhận sau khi bạn đã cập nhật trên Seller Central — cần URL listing hoặc ghi chú bằng chứng (≥ 5 ký tự).</p>
                    <input value={pubUrl} onChange={(e) => setPubUrl(e.target.value)} placeholder="URL listing / A+ (https://…)" className={input} />
                    <input value={pubNote} onChange={(e) => setPubNote(e.target.value)} placeholder="Ghi chú bằng chứng (ai, khi nào, ảnh chụp lưu ở đâu)" className={input} />
                    <div className="flex gap-2">
                      <button className={btn.success} disabled={!(pubUrl.trim().startsWith('http') || pubNote.trim().length >= 5)} onClick={() => recordPublish(v)}>Xác nhận đã publish</button>
                      <button className={btn.ghost} onClick={() => setPubFor(null)}>Huỷ</button>
                    </div>
                  </div>
                )}
                {(pubRecs[v.id]?.length ?? 0) > 0 && (
                  <ul className="px-4 pb-3 text-xs text-gray-600 space-y-0.5">
                    {pubRecs[v.id].map((r) => (
                      <li key={r.id}>{r.kind === 'publish' ? '✔ Publish' : '↩ Rollback'} · {r.channel === 'manual' ? 'thủ công' : 'API'} · {new Date(r.performed_at).toLocaleString('vi-VN')} · {r.verify_status === 'manual_verified' ? 'xác nhận tay' : r.verify_status}
                        {r.evidence_url && <> · <a className="text-blue-700 underline" href={r.evidence_url} target="_blank" rel="noreferrer">bằng chứng</a></>}
                        {r.evidence_note && <> · {r.evidence_note}</>}</li>
                    ))}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
      )}

      {impact && <ImpactBox data={impact} onClose={() => setImpact(null)} />}
      {impact && impact.ok === true && <CvrSeries versionId={String(impact.version_id)} />}
    </div>
  );
}

// ============================================================
function Editor({ kind, base, isNew, facts, skuId, tenantId, premium, onClose, onSaved, onError }: {
  kind: Kind; base: Version | null; isNew: boolean; facts: Fact[]; skuId: string; tenantId: string; premium: boolean; onClose: () => void; onSaved: () => void; onError: (m: string | null) => void;
}) {
  const [body, setBody] = React.useState<Record<string, unknown>>(() => (base ? structuredClone(base.body) : emptyBody(kind)));
  const [claims, setClaims] = React.useState<{ text: string; fact_id: string | null }[]>(() => (base ? [...base.claims] : []));
  const [brief, setBrief] = React.useState(base?.brief ?? '');
  const [pre, setPre] = React.useState<Compliance>(null);
  const [busy, setBusy] = React.useState(false);

  async function precheck() {
    const { data, error } = await supabase.rpc('check_content_compliance', { p_tenant: tenantId, p_sku: skuId, p_kind: kind, p_body: body, p_claims: claims });
    if (error) onError(error.message); else setPre(data as Compliance);
  }
  async function save() {
    setBusy(true); onError(null);
    const payload = { body, claims, brief: brief || null };
    const { error } = isNew || !base
      ? await supabase.from('content_versions').insert({ tenant_id: tenantId, sku_id: skuId, kind, parent_id: base?.id ?? null, origin: 'human', ...payload })
      : await supabase.from('content_versions').update(payload).eq('id', base.id);
    setBusy(false);
    if (error) onError(error.message); else onSaved();
  }

  const items = (body.items as string[]) ?? [];
  const modules = (body.modules as ModuleData[]) ?? [];
  const [showPrev, setShowPrev] = React.useState<'desktop' | 'mobile' | null>(null);
  const text = String(body.text ?? '');
  const [templates, setTemplates] = React.useState<{ id: string; key: string; name: string; use_case: string; description: string | null; tenant_id: string | null }[]>([]);
  const [tplMsg, setTplMsg] = React.useState<string | null>(null);
  React.useEffect(() => {
    if (kind !== 'aplus') return;
    (async () => {
      const { data } = await supabase.from('aplus_templates').select('id,key,name,use_case,description,tenant_id').eq('is_active', true).order('tenant_id', { nullsFirst: false }).limit(50);
      setTemplates(data ?? []);
    })();
  }, [kind]);
  async function applyTemplate(id: string) {
    if (!id) return;
    if (modules.length > 0 && !confirm('Thay toàn bộ module hiện tại bằng template?')) return;
    const { data, error } = await supabase.rpc('build_aplus_from_template', { p_template: id, p_sku: skuId });
    if (error) { onError(error.message); return; }
    const r = data as { body: Record<string, unknown>; claims: { text: string; fact_id: string | null }[]; missing_facts: string[]; brief: string };
    setBody(r.body); setClaims(r.claims); setBrief(r.brief); setPre(null);
    setTplMsg(r.missing_facts.length ? `Thiếu fact đã xác minh: ${r.missing_facts.join(', ')} — bổ sung ở tab Product Facts hoặc xoá placeholder trước khi gửi QA.` : 'Đã điền từ template; mọi số liệu đều gắn với fact đã xác minh.');
  }

  return (
    <div className="border border-indigo-200 bg-indigo-50/40 rounded-lg p-4 space-y-3">
      <p className="text-sm font-medium">{isNew ? `Draft mới – ${KIND_LABEL[kind]}${base ? ` (từ v${base.version})` : ''}` : `Sửa v${base?.version}`}</p>

      {kind === 'bullets' && (
        <div className="space-y-2">
          {items.map((b, i) => (
            <div key={i} className="flex gap-2">
              <textarea value={b} onChange={(e) => { const n = [...items]; n[i] = e.target.value; setBody({ items: n }); }} className={`${input} h-16 flex-1`} placeholder={`Bullet ${i + 1}`} />
              <button className={btn.ghost} onClick={() => setBody({ items: items.filter((_, j) => j !== i) })}>✕</button>
            </div>
          ))}
          {items.length < 5 && <button className={btn.secondary} onClick={() => setBody({ items: [...items, ''] })}>+ Bullet</button>}
        </div>
      )}
      {kind === 'aplus' && (
        <div className="space-y-3">
          {templates.length > 0 && (
            <div className="rounded-md border border-dashed border-indigo-300 bg-white p-3 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium">Template A+</span>
                <select className={`${input} w-72`} defaultValue="" onChange={(e) => { void applyTemplate(e.target.value); e.target.value = ''; }}>
                  <option value="">— chọn template để điền từ Product Facts —</option>
                  {templates.map((t) => <option key={t.id} value={t.id}>{t.name}{t.tenant_id ? ' (riêng)' : ''}</option>)}
                </select>
                <span className="text-xs text-gray-500">Placeholder {'{fact:key}'} chỉ điền từ fact đã xác minh; không bịa số liệu.</span>
              </div>
              {tplMsg && <p className={`mt-2 text-xs ${tplMsg.startsWith('Thiếu') ? 'text-amber-700' : 'text-emerald-700'}`}>{tplMsg}</p>}
            </div>
          )}
          <AplusEditor modules={modules as unknown as ModuleData[]} onChange={(m) => setBody({ modules: m })} facts={facts} premium={premium} />
          <div className="flex items-center gap-2 text-xs">
            <button className={btn.ghost} onClick={() => setShowPrev(showPrev === 'desktop' ? null : 'desktop')}>{showPrev === 'desktop' ? 'Ẩn preview' : 'Preview desktop'}</button>
            <button className={btn.ghost} onClick={() => setShowPrev(showPrev === 'mobile' ? null : 'mobile')}>{showPrev === 'mobile' ? 'Ẩn preview' : 'Preview mobile'}</button>
          </div>
          {showPrev && <AplusPreview modules={modules as unknown as ModuleData[]} mobile={showPrev === 'mobile'} />}
        </div>
      )}
      {(kind === 'title' || kind === 'description' || kind === 'backend_keywords') && (
        <textarea value={text} onChange={(e) => setBody({ text: e.target.value })} className={`${input} ${kind === 'title' ? 'h-16' : 'h-40'}`} placeholder={kind === 'title' ? 'Title ≤ 200 ký tự' : kind === 'backend_keywords' ? 'Từ khoá cách nhau bằng dấu cách, ≤ 249 bytes' : 'Mô tả ≤ 2000 ký tự'} />
      )}
      <p className="text-xs text-gray-500">{kind === 'backend_keywords' ? `${new TextEncoder().encode(text).length} bytes` : `${bodyToText(kind, body).length} ký tự`}</p>

      <div>
        <p className="text-sm font-medium mb-1">Claims → Product Facts</p>
        {facts.length === 0 && <p className="text-xs text-amber-700">Chưa có fact đã xác minh — mọi claim sẽ bị gate chặn.</p>}
        <div className="space-y-1">
          {claims.map((c, i) => (
            <div key={i} className="flex gap-2">
              <input value={c.text} onChange={(e) => { const n = [...claims]; n[i] = { ...c, text: e.target.value }; setClaims(n); }} className={`${input} flex-1`} placeholder="Câu claim trong nội dung (vd: 750 ml)" />
              <select value={c.fact_id ?? ''} onChange={(e) => { const n = [...claims]; n[i] = { ...c, fact_id: e.target.value || null }; setClaims(n); }} className={`${input} w-56`}>
                <option value="">— chọn fact —</option>
                {facts.map((f) => <option key={f.id} value={f.id}>{f.key}: {f.value}{f.unit ? ` ${f.unit}` : ''}</option>)}
              </select>
              <button className={btn.ghost} onClick={() => setClaims(claims.filter((_, j) => j !== i))}>✕</button>
            </div>
          ))}
        </div>
        <button className={`${btn.ghost} mt-1`} onClick={() => setClaims([...claims, { text: '', fact_id: null }])}>+ Claim</button>
      </div>

      <input value={brief} onChange={(e) => setBrief(e.target.value)} className={input} placeholder="Brief / lý do thay đổi (vd: review than phiền nắp rò → thêm hướng dẫn khoá nắp)" />

      {pre && (
        <div className={`rounded-md p-3 text-sm ${pre.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>
          <p className="font-medium">Compliance Gate: {pre.ok ? 'đạt' : `${pre.blocks} lỗi chặn`}{pre.warns ? ` · ${pre.warns} cảnh báo` : ''}</p>
          <ul className="mt-1 text-xs space-y-0.5">{pre.issues.map((is, i) => <li key={i}>{is.severity === 'block' ? '⛔' : '⚠'} {is.msg}</li>)}</ul>
        </div>
      )}
      <div className="flex gap-2">
        <button className={btn.secondary} onClick={precheck}>Kiểm tra gate</button>
        <button className={btn.primary} disabled={busy} onClick={save}>{busy ? 'Đang lưu…' : isNew ? 'Lưu draft' : 'Lưu'}</button>
        <button className={btn.ghost} onClick={onClose}>Huỷ</button>
      </div>
    </div>
  );
}

// ============================================================
function ImpactBox({ data, onClose }: { data: Record<string, unknown>; onClose: () => void }) {
  if (!data.ok) return <div className="rounded-md bg-gray-50 p-3 text-sm">{String(data.note)} <button className={btn.ghost} onClick={onClose}>Đóng</button></div>;
  const b = data.before as Record<string, number | null>; const a = data.after as Record<string, number | null>;
  const conf = String(data.confidence);
  const confCls = conf === 'moderate' ? 'bg-emerald-50 text-emerald-800' : conf === 'confounded' ? 'bg-amber-50 text-amber-800' : 'bg-gray-100 text-gray-700';
  const CL: Record<string, string> = { moderate: 'Độ tin cậy vừa', confounded: 'Bị nhiễu bởi thay đổi đồng thời', low: 'Độ tin cậy thấp', insufficient_data: 'Chưa đủ dữ liệu' };
  const pct = (x: number | null) => (x == null ? '—' : `${(x * 100).toFixed(2)}%`);
  return (
    <div className="rounded-lg border border-gray-200 p-4 space-y-2 text-sm">
      <div className="flex items-center gap-2"><p className="font-medium">Tác động content – {String(data.days)} ngày trước/sau publish</p><span className={`text-xs px-2 py-0.5 rounded ${confCls}`}>{CL[conf] ?? conf}</span><span className="flex-1" /><button className={btn.ghost} onClick={onClose}>Đóng</button></div>
      <table className="text-sm">
        <thead><tr className="text-gray-500 text-xs"><th className="text-left pr-4">Chỉ số</th><th className="text-right pr-4">Trước</th><th className="text-right pr-4">Sau</th></tr></thead>
        <tbody>
          <tr><td className="pr-4">Sessions</td><td className="text-right pr-4 tabular-nums">{b.sessions}</td><td className="text-right pr-4 tabular-nums">{a.sessions}</td></tr>
          <tr><td className="pr-4">Đơn vị</td><td className="text-right pr-4 tabular-nums">{b.units}</td><td className="text-right pr-4 tabular-nums">{a.units}</td></tr>
          <tr><td className="pr-4 font-medium">CVR</td><td className="text-right pr-4 tabular-nums">{pct(b.cvr)}</td><td className="text-right pr-4 tabular-nums font-medium">{pct(a.cvr)} {data.cvr_delta_pct != null && <span className={Number(data.cvr_delta_pct) >= 0 ? 'text-emerald-700' : 'text-red-700'}>({Number(data.cvr_delta_pct) >= 0 ? '+' : ''}{String(data.cvr_delta_pct)}%)</span>}</td></tr>
          <tr><td className="pr-4">Giá TB</td><td className="text-right pr-4 tabular-nums">{b.avg_price}</td><td className="text-right pr-4 tabular-nums">{a.avg_price}</td></tr>
          <tr><td className="pr-4">Chi phí ads</td><td className="text-right pr-4 tabular-nums">{b.ad_spend}</td><td className="text-right pr-4 tabular-nums">{a.ad_spend}</td></tr>
        </tbody>
      </table>
      {(data.concurrent_changes as string[]).length > 0 && <ul className="text-xs text-amber-800 list-disc pl-5">{(data.concurrent_changes as string[]).map((c) => <li key={c}>{c}</li>)}</ul>}
      <p className="text-xs text-gray-600">{String(data.note)}</p>
    </div>
  );
}

// ============================================================
function CvrSeries({ versionId }: { versionId: string }) {
  const [rows, setRows] = React.useState<CvrPoint[] | null>(null);
  const [days, setDays] = React.useState(14);
  React.useEffect(() => {
    (async () => {
      const { data } = await supabase.rpc('content_cvr_series', { p_version: versionId, p_days: days });
      setRows((data ?? []) as CvrPoint[]);
    })();
  }, [versionId, days]);
  if (!rows) return null;
  const agg = (ph: 'before' | 'after') => { const r = rows.filter((x) => x.phase === ph && x.sessions != null); const s = r.reduce((a, x) => a + (x.sessions ?? 0), 0); const u = r.reduce((a, x) => a + (x.units ?? 0), 0); const c = r.filter((x) => x.control_cvr != null); return { days: r.length, cvr: s > 0 ? u / s : null, ctrl: c.length ? c.reduce((a, x) => a + (x.control_cvr ?? 0), 0) / c.length : null }; };
  const b = agg('before'), a = agg('after');
  const pct = (x: number | null) => (x == null ? '—' : `${(x * 100).toFixed(2)}%`);
  const rel = b.cvr && a.cvr ? ((a.cvr / b.cvr - 1) * 100) : null;
  const relCtrl = b.ctrl && a.ctrl ? ((a.ctrl / b.ctrl - 1) * 100) : null;
  return (
    <div className="rounded-lg border border-gray-200 p-4 space-y-2 text-sm">
      <div className="flex flex-wrap items-center gap-3">
        <p className="font-medium">CVR trước / sau publish</p>
        <select value={days} onChange={(e) => setDays(Number(e.target.value))} className={`${input} w-28`}>{[7, 14, 28].map((d) => <option key={d} value={d}>±{d} ngày</option>)}</select>
        <span className="text-xs text-gray-600">Trước {pct(b.cvr)} ({b.days}d) → Sau {pct(a.cvr)} ({a.days}d){rel != null && <b className={rel >= 0 ? 'text-emerald-700' : 'text-red-700'}> {rel >= 0 ? '+' : ''}{rel.toFixed(1)}%</b>}</span>
        <span className="text-xs text-gray-500">Đối chứng: {pct(b.ctrl)} → {pct(a.ctrl)}{relCtrl != null && ` (${relCtrl >= 0 ? '+' : ''}${relCtrl.toFixed(1)}%)`}</span>
      </div>
      {rows.some((r) => r.sessions != null) ? <CvrBeforeAfterChart data={rows} /> : <p className="text-xs text-gray-500">Chưa có dữ liệu sessions theo ngày trong cửa sổ này (cần feed orders/sales & traffic).</p>}
      <p className="text-xs text-gray-500">Đường xám = CVR trung bình các ASIN cùng tenant không có thay đổi trong cửa sổ. Nếu đường xám cũng dịch chuyển tương tự, thay đổi có thể do thị trường/mùa vụ chứ không phải content.</p>
    </div>
  );
}
