'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { Badge, btn, input } from '@/components/ui';

type Source = { id: string; tenant_id: string; kind: 'csv_manual' | 'sp_api' | 'ads_api'; name: string; enabled: boolean; feeds: string[]; config: Record<string, unknown>; status: string; last_run_at: string | null; last_error: string | null; credential_ref: string | null };
type FeedMeta = { feed_key: string; label: string };
type SyncJob = { id: string; feed_key: string; feed_label: string; window_start: string; window_end: string; triggered_by: string; status: string; stage: string | null; attempt: number; max_attempts: number; next_attempt_at: string; last_error: string | null; error_class: string | null; created_at: string; finished_at: string | null; result: Record<string, unknown> | null };
type Health = { cron_status: 'ok' | 'missing' | 'unknown'; vault_enabled: boolean; pg_net_enabled: boolean; worker_last_seen: string | null; worker_status: 'ok' | 'stale' | 'unknown'; queued: number; running: number; failed_24h: number; write_back_enabled: boolean };

const FN_URL = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/amazon-sync`;
const fmt = (s: string | null) => (s ? new Date(s).toLocaleString('vi-VN', { hour12: false }) : '—');
const JOB_ST: Record<string, string> = { queued: 'bg-gray-100 text-gray-700', running: 'bg-sky-100 text-sky-800', succeeded: 'bg-emerald-100 text-emerald-800', partial: 'bg-amber-100 text-amber-800', failed: 'bg-red-100 text-red-800', cancelled: 'bg-gray-100 text-gray-500' };
const JOB_VI: Record<string, string> = { queued: 'chờ', running: 'đang chạy', succeeded: 'xong', partial: 'một phần', failed: 'lỗi', cancelled: 'đã huỷ' };
const ERR_VI: Record<string, string> = { auth: 'xác thực', rate_limit: 'giới hạn tần suất', permission: 'thiếu quyền/role Amazon', amazon: 'lỗi phía Amazon', parse: 'định dạng dữ liệu', ingest: 'ghi dữ liệu', network: 'mạng', unknown: 'không rõ' };

async function callFn(body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const { data: { session } } = await supabase.auth.getSession();
  const res = await fetch(FN_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session?.access_token ?? ''}`, apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '' }, body: JSON.stringify(body) });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((j as { error?: string }).error ?? `Edge Function ${res.status} — đã deploy amazon-sync chưa?`);
  return j as Record<string, unknown>;
}

export function HealthStrip({ tenantId, refreshKey }: { tenantId: string; refreshKey: number }) {
  const [h, setH] = React.useState<Health | null>(null);
  const [err, setErr] = React.useState<string | null>(null);
  React.useEffect(() => {
    (async () => {
      const { data, error } = await supabase.rpc('connector_health', { t: tenantId });
      if (error) setErr(error.message.includes('connector_health') ? 'Chưa chạy migration 023' : error.message); else setH(data as Health);
    })();
  }, [tenantId, refreshKey]);
  if (err) return <p className="text-xs text-amber-700">{err}</p>;
  if (!h) return null;
  const pill = (label: string, st: string) => <span className={`inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs ${st === 'ok' ? 'bg-emerald-50 text-emerald-800' : st === 'unknown' ? 'bg-gray-100 text-gray-600' : 'bg-amber-50 text-amber-800'}`}>{label}: <b>{st === 'ok' ? 'hoạt động' : st === 'missing' ? 'chưa cài' : st === 'stale' ? 'không thấy >30 phút' : 'chưa xác định'}</b></span>;
  return (
    <div className="flex flex-wrap items-center gap-2 text-xs">
      {pill('Lịch pg_cron', h.cron_status)}
      {pill('Worker', h.worker_status)}
      <span className="rounded bg-gray-100 px-2 py-0.5 text-gray-700">hàng đợi {h.queued} · đang chạy {h.running} · lỗi 24h {h.failed_24h}</span>
      {!h.vault_enabled && <span className="rounded bg-red-50 px-2 py-0.5 text-red-700">Vault chưa bật — không lưu được credential</span>}
      <span className="rounded bg-emerald-50 px-2 py-0.5 text-emerald-800">Write‑back: TẮT (chỉ đọc)</span>
      {h.worker_last_seen && <span className="text-gray-500">worker lần cuối {fmt(h.worker_last_seen)}</span>}
    </div>
  );
}

export function ConnectorPanel({ source, feeds, canEdit, canImport, onChanged }: { source: Source; feeds: FeedMeta[]; canEdit: boolean; canImport: boolean; onChanged: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [cred, setCred] = React.useState({ client_id: '', client_secret: '', refresh_token: '', profile_id: '' });
  const [busy, setBusy] = React.useState<string | null>(null);
  const [msg, setMsg] = React.useState<{ ok: boolean; text: string } | null>(null);
  const [profiles, setProfiles] = React.useState<{ id: string; country: string; name?: string; type?: string }[]>([]);
  const [hasSecret, setHasSecret] = React.useState<boolean | null>(null);
  const [feed, setFeed] = React.useState(source.feeds[0] ?? '');
  const isApi = source.kind !== 'csv_manual';

  React.useEffect(() => {
    (async () => {
      if (!isApi || !source.credential_ref) { setHasSecret(false); return; }
      const { data } = await supabase.rpc('connector_secret_exists', { t: source.tenant_id, p_ref: source.credential_ref });
      setHasSecret(data === true);
    })();
  }, [isApi, source]);

  if (!isApi) return null;

  async function storeCredential() {
    setBusy('cred'); setMsg(null);
    try {
      const r = await callFn({ action: 'store_credential', source_id: source.id, credential: { ...cred, profile_id: cred.profile_id || undefined } });
      const t = r.test as { ok: boolean; error?: string; profiles?: typeof profiles } | undefined;
      setProfiles(t?.profiles ?? []);
      setMsg({ ok: !!t?.ok, text: t?.ok ? 'Đã lưu vào Vault và kết nối thành công.' : `Đã lưu vào Vault nhưng kết nối lỗi: ${t?.error ?? 'xem chi tiết nguồn'}` });
      setCred({ client_id: '', client_secret: '', refresh_token: '', profile_id: '' });
      onChanged();
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : String(e) }); } finally { setBusy(null); }
  }
  async function test() {
    setBusy('test'); setMsg(null);
    try {
      const r = await callFn({ action: 'test_connection', source_id: source.id });
      setProfiles((r.profiles as typeof profiles) ?? []);
      setMsg({ ok: r.ok === true, text: r.ok ? `Kết nối OK (${String(r.kind)} · ${String(r.region)})` : `Lỗi: ${String(r.error ?? 'không rõ')}` });
      onChanged();
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : String(e) }); } finally { setBusy(null); }
  }
  async function backfill(days: 1 | 7 | 28) {
    if (!feed) return;
    setBusy(`bf${days}`); setMsg(null);
    const { data, error } = await supabase.rpc('backfill_sync', { p_source: source.id, p_feed: feed, p_days: days });
    if (error) setMsg({ ok: false, text: error.message });
    else {
      const d = data as { jobs: number; from?: string; to?: string; note?: string };
      setMsg({ ok: true, text: `Đã xếp ${d.jobs} job ${d.from ? `(${d.from} → ${d.to})` : ''} ${d.note ?? ''}. Worker sẽ xử lý theo lịch; bấm "Chạy ngay" để không chờ.` });
      onChanged();
    }
    setBusy(null);
  }
  async function runNow() {
    setBusy('run'); setMsg(null);
    try {
      const r = await callFn({ action: 'run_now', tenant_id: source.tenant_id });
      const res = (r.results as { status: string; error?: string }[]) ?? [];
      setMsg({ ok: true, text: res.length === 0 ? 'Không có job chờ.' : `Đã xử lý ${res.length} job: ${res.map((x) => x.status).join(', ')}${res.some((x) => x.error) ? ' — ' + res.filter((x) => x.error).map((x) => x.error).join(' | ') : ''}` });
      onChanged();
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : String(e) }); } finally { setBusy(null); }
  }

  return (
    <div className="mt-2 w-full rounded-lg border border-gray-200 bg-gray-50/60 p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs text-gray-600">Credential: {hasSecret == null ? '…' : hasSecret ? <Badge className="bg-emerald-50 text-emerald-700">đã lưu trong Vault</Badge> : <Badge className="bg-amber-50 text-amber-800">chưa có</Badge>}</span>
        {source.config.verified_at ? <span className="text-xs text-gray-500">xác minh lúc {fmt(String(source.config.verified_at))}</span> : null}
        {source.kind === 'ads_api' && <span className="text-xs text-gray-500">profile: {String(source.config.ads_profile_id ?? '—')}</span>}
        {source.kind === 'sp_api' && <span className="text-xs text-gray-500">marketplace: {String(source.config.marketplace_id ?? '—')} · region {String(source.config.region ?? 'tự động')}</span>}
        <span className="flex-1" />
        {canEdit && <button className={btn.secondary} onClick={() => setOpen((o) => !o)}>{open ? 'Đóng' : hasSecret ? 'Thay credential' : 'Nhập credential'}</button>}
        {canEdit && hasSecret && <button className={btn.secondary} disabled={busy != null} onClick={test}>{busy === 'test' ? 'Đang thử…' : 'Thử kết nối'}</button>}
      </div>

      {open && canEdit && (
        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          <p className="sm:col-span-2 text-xs text-gray-600">Secret được gửi thẳng tới Edge Function và lưu vào <b>Supabase Vault</b>; không đi qua bảng dữ liệu, không hiển thị lại. Ứng dụng chỉ dùng quyền <b>đọc</b> (Orders, Reports, Brand Analytics cho Sales & Traffic; Ads: reporting).</p>
          <label className="text-xs">LWA Client ID<input className={input} value={cred.client_id} onChange={(e) => setCred({ ...cred, client_id: e.target.value })} placeholder="amzn1.application-oa2-client.…" /></label>
          <label className="text-xs">LWA Client Secret<input className={input} type="password" value={cred.client_secret} onChange={(e) => setCred({ ...cred, client_secret: e.target.value })} /></label>
          <label className="text-xs sm:col-span-2">Refresh token<input className={input} type="password" value={cred.refresh_token} onChange={(e) => setCred({ ...cred, refresh_token: e.target.value })} placeholder="Atzr|…" /></label>
          {source.kind === 'ads_api' && <label className="text-xs">Ads profile ID (tuỳ chọn — để trống sẽ tự chọn nếu chỉ có 1)<input className={input} value={cred.profile_id} onChange={(e) => setCred({ ...cred, profile_id: e.target.value })} /></label>}
          <div className="sm:col-span-2"><button className={btn.primary} disabled={busy != null || !cred.client_id || !cred.client_secret || !cred.refresh_token} onClick={storeCredential}>{busy === 'cred' ? 'Đang lưu & thử…' : 'Lưu vào Vault và thử kết nối'}</button></div>
        </div>
      )}

      {profiles.length > 1 && <p className="mt-2 text-xs text-amber-800">Tài khoản Ads có {profiles.length} profile: {profiles.map((p) => `${p.id} (${p.country}${p.name ? ' · ' + p.name : ''})`).join('; ')}. Nhập lại credential kèm Ads profile ID để chọn.</p>}

      {source.status === 'connected' && canImport && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <span className="text-xs text-gray-600">Kéo dữ liệu:</span>
          <select className={`${input} !w-auto`} value={feed} onChange={(e) => setFeed(e.target.value)}>
            {source.feeds.map((k) => <option key={k} value={k}>{feeds.find((f) => f.feed_key === k)?.label ?? k}</option>)}
          </select>
          {([1, 7, 28] as const).map((d) => <button key={d} className={btn.secondary} disabled={busy != null} onClick={() => backfill(d)}>{busy === `bf${d}` ? '…' : `Backfill ${d} ngày`}</button>)}
          <button className={btn.primary} disabled={busy != null} onClick={runNow}>{busy === 'run' ? 'Đang chạy…' : 'Chạy ngay'}</button>
        </div>
      )}
      {msg && <p className={`mt-2 text-xs ${msg.ok ? 'text-emerald-700' : 'text-red-700'}`}>{msg.text}</p>}
    </div>
  );
}

export function SyncJobsTable({ tenantId, refreshKey, canImport }: { tenantId: string; refreshKey: number; canImport: boolean }) {
  const [jobs, setJobs] = React.useState<SyncJob[]>([]);
  const [tick, setTick] = React.useState(0);
  React.useEffect(() => {
    (async () => {
      const { data } = await supabase.from('v_sync_jobs').select('*').eq('tenant_id', tenantId).order('created_at', { ascending: false }).limit(30);
      setJobs((data ?? []) as SyncJob[]);
    })();
  }, [tenantId, refreshKey, tick]);
  React.useEffect(() => {
    if (!jobs.some((j) => j.status === 'queued' || j.status === 'running')) return;
    const id = setInterval(() => setTick((t) => t + 1), 15000);
    return () => clearInterval(id);
  }, [jobs]);
  if (jobs.length === 0) return <p className="px-5 py-4 text-sm text-gray-500">Chưa có job đồng bộ nào. Kết nối nguồn API rồi bấm Backfill.</p>;
  const cancel = async (id: string) => { const { error } = await supabase.rpc('cancel_sync_job', { p_job: id }); if (error) alert(error.message); else setTick((t) => t + 1); };
  return (
    <div className="overflow-x-auto px-5 py-3">
      <table className="w-full text-sm">
        <thead className="text-left text-xs uppercase text-gray-500 border-b"><tr><th className="py-2 pr-3">Tạo lúc</th><th className="pr-3">Feed</th><th className="pr-3">Cửa sổ</th><th className="pr-3">Trạng thái</th><th className="pr-3">Bước</th><th className="pr-3">Lần thử</th><th className="pr-3">Kết quả / lỗi</th><th></th></tr></thead>
        <tbody>
          {jobs.map((j) => {
            const r = j.result ?? {};
            return (
              <tr key={j.id} className="border-b last:border-0 align-top">
                <td className="py-1.5 pr-3 text-gray-600 whitespace-nowrap">{fmt(j.created_at)}<div className="text-[10px] text-gray-400">{j.triggered_by}</div></td>
                <td className="pr-3">{j.feed_label}<div className="font-mono text-[10px] text-gray-400">{j.feed_key}</div></td>
                <td className="pr-3 text-gray-600 whitespace-nowrap">{j.window_start === j.window_end ? j.window_start : `${j.window_start} → ${j.window_end}`}</td>
                <td className="pr-3"><Badge className={JOB_ST[j.status]}>{JOB_VI[j.status] ?? j.status}</Badge></td>
                <td className="pr-3 text-gray-500 text-xs">{j.stage ?? '—'}</td>
                <td className="pr-3 text-gray-500 text-xs">{j.attempt}/{j.max_attempts}{j.status === 'queued' && j.attempt > 0 && <div>thử lại {fmt(j.next_attempt_at)}</div>}</td>
                <td className="pr-3 text-xs max-w-[360px]">
                  {j.status === 'succeeded' || j.status === 'partial' ? (
                    r.duplicate ? <span className="text-gray-500">trùng file đã ghi trước</span> : r.empty ? <span className="text-gray-500">Amazon trả 0 dòng (không ghi 0)</span> : <span className="text-gray-700">{String(r.rows_inserted ?? 0)}+ · {String(r.rows_updated ?? 0)}↻ · {String(r.rows_skipped ?? 0)}= · {String((Number(r.rows_error ?? 0) + Number(r.rows_invalid ?? 0)))} lỗi</span>
                  ) : j.last_error ? <span className="text-red-700">{j.error_class ? `[${ERR_VI[j.error_class] ?? j.error_class}] ` : ''}{j.last_error}</span> : <span className="text-gray-400">—</span>}
                </td>
                <td>{canImport && j.status === 'queued' && <button className="text-xs text-gray-500 hover:text-red-600" onClick={() => cancel(j.id)}>huỷ</button>}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
