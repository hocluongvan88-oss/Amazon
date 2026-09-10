// Edge Function: amazon-sync — worker READ-ONLY kéo dữ liệu Amazon vào hệ thống qua ingest_* (cùng hợp đồng với CSV).
// Deploy: supabase functions deploy amazon-sync --no-verify-jwt=false
// Gọi: POST /functions/v1/amazon-sync  Authorization: Bearer <service_role>  body: {action:'tick'|'test_connection'|'store_credential'|'schedule', ...}
// Từ UI (user JWT): action 'store_credential' và 'test_connection' được phép nếu user có policy.edit trên tenant (function tự kiểm).
// KHÔNG có write-back: không gọi bất kỳ endpoint ghi nào của Amazon.

import { createClient, SupabaseClient } from 'npm:@supabase/supabase-js@2';
import {
  AmazonError, MARKETPLACE, type Region, type SpCred, type AdsCred, lwaToken,
  spCreateReport, spGetReport, spDownloadDocument, adsListProfiles, adsCreateReport, adsGetReport, adsDownload,
  mapOrders, mapReturns, mapInventory, mapSalesTraffic, mapAdsAdvertised, mapAdsSearchTerms, ADS_ADVERTISED_COLUMNS, ADS_SEARCH_TERM_COLUMNS, type RawRow,
} from './amazon.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const WORKER = `edge-${crypto.randomUUID().slice(0, 8)}`;
const admin: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

type Job = { id: string; tenant_id: string; source_id: string; feed_key: string; window_start: string; window_end: string; triggered_by: string; attempt: number; external_ref: string | null; stage: string | null };
type Claimed = { job: Job; source: { id: string; kind: 'sp_api' | 'ads_api'; config: Record<string, string>; credential_ref: string }; feed: { feed_key: string; import_kind: string; amazon_report_type: string; settlement_lag_days: number }; tenant: { id: string; marketplace: string } };

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type, apikey' } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

async function loadCred(ref: string): Promise<SpCred & { profile_id?: string }> {
  const raw = await rpc<string | null>('connector_secret_get', { p_ref: ref });
  if (!raw) throw new AmazonError('Không tìm thấy credential trong Vault', 'auth', false);
  try { return JSON.parse(raw); } catch { throw new AmazonError('Credential trong Vault không phải JSON', 'auth', false); }
}
function regionOf(cfg: Record<string, string>, marketplace: string): Region {
  return (cfg.region as Region) || MARKETPLACE[marketplace]?.region || 'na';
}
function marketplaceId(cfg: Record<string, string>, marketplace: string): string {
  const id = cfg.marketplace_id || MARKETPLACE[marketplace]?.id;
  if (!id) throw new AmazonError(`Không xác định marketplaceId cho ${marketplace} — đặt config.marketplace_id`, 'permission', false);
  return id;
}

// ---------------- ingest qua cùng hợp đồng CSV ----------------
async function ingest(c: Claimed, rows: RawRow[], externalRef: string): Promise<Record<string, unknown>> {
  const j = c.job;
  const payload = JSON.stringify(rows);
  const hashBuf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${c.feed.import_kind}\n${payload}`));
  const fileHash = Array.from(new Uint8Array(hashBuf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  const filename = `${c.source.kind}:${c.feed.amazon_report_type}:${j.window_start}..${j.window_end}:${externalRef}`;
  const opened = await rpc<{ batch_id: string; duplicate: boolean }>('ingest_open', { p_tenant: j.tenant_id, p_kind: c.feed.import_kind, p_filename: filename, p_file_hash: fileHash, p_column_map: { _api: externalRef }, p_source: c.source.id });
  if (opened.duplicate) return { batch_id: opened.batch_id, duplicate: true, rows: rows.length };
  if (rows.length === 0) {
    // Không có dòng nào: KHÔNG ghi zero. Ghi run 'succeeded' rows 0 để freshness biết đã kiểm tra.
    const run = await admin.from('ingestion_runs').insert({ tenant_id: j.tenant_id, source_id: c.source.id, feed_key: c.feed.feed_key, status: 'succeeded', triggered_by: j.triggered_by === 'manual' ? 'manual' : j.triggered_by === 'backfill' ? 'backfill' : 'schedule', window_start: j.window_start, window_end: j.window_end, rows_total: 0, rows_ok: 0, external_ref: externalRef, started_at: new Date().toISOString(), finished_at: new Date().toISOString() }).select('id').single();
    return { batch_id: opened.batch_id, rows: 0, run_id: run.data?.id, empty: true };
  }
  for (let i = 0; i < rows.length; i += 1000) {
    await rpc('ingest_add_rows', { p_batch: opened.batch_id, p_rows: rows.slice(i, i + 1000), p_offset: i + 1 });
  }
  const dry = await rpc<{ rows_valid: number; rows_invalid: number; can_commit: boolean; errors: unknown[] }>('ingest_dry_run', { p_batch: opened.batch_id });
  if (!dry.can_commit) throw new AmazonError(`Không có dòng hợp lệ (${dry.rows_invalid} lỗi): ${JSON.stringify(dry.errors.slice(0, 3))}`, 'parse', false);
  const res = await rpc<{ run_id: string; status: string; rows_inserted: number; rows_updated: number; rows_skipped: number; rows_error: number; rows_invalid: number }>('ingest_commit', { p_batch: opened.batch_id });
  await rpc('set_run_trigger', { p_run: res.run_id, p_trigger: j.triggered_by === 'manual' ? 'manual' : j.triggered_by === 'backfill' ? 'backfill' : 'schedule', p_external_ref: externalRef });
  return { batch_id: opened.batch_id, ...res, rows: rows.length };
}

// ---------------- SP-API pipeline ----------------
async function runSp(c: Claimed): Promise<Record<string, unknown>> {
  const cred = await loadCred(c.source.credential_ref);
  const region = regionOf(c.source.config, c.tenant.marketplace);
  const mkId = marketplaceId(c.source.config, c.tenant.marketplace);
  const token = await lwaToken(cred);
  const j = c.job;
  let reportId = j.external_ref && j.stage && j.stage !== 'auth' && j.stage !== 'create_report' ? j.external_ref : null;

  if (!reportId) {
    await rpc('sync_job_progress', { p_job: j.id, p_stage: 'create_report' });
    const spec: Parameters<typeof spCreateReport>[2] = { reportType: c.feed.amazon_report_type, marketplaceIds: [mkId] };
    if (c.feed.feed_key === 'orders_daily') {
      spec.dataStartTime = `${j.window_start}T00:00:00Z`; spec.dataEndTime = `${j.window_end}T23:59:59Z`;
    } else if (c.feed.feed_key === 'returns') {
      spec.dataStartTime = `${j.window_start}T00:00:00Z`; spec.dataEndTime = `${j.window_end}T23:59:59Z`;
    } else if (c.feed.feed_key === 'sales_traffic_daily') {
      spec.dataStartTime = `${j.window_start}T00:00:00Z`; spec.dataEndTime = `${j.window_end}T23:59:59Z`;
      spec.reportOptions = { dateGranularity: 'DAY', asinGranularity: 'CHILD' };
    }
    reportId = await spCreateReport(region, token, spec);
    await rpc('sync_job_progress', { p_job: j.id, p_stage: 'poll', p_external_ref: reportId });
  }

  // poll tối đa ~100s trong 1 invocation; nếu chưa xong → retry sau (giữ reportId)
  let docId: string | undefined;
  for (let i = 0; i < 10; i++) {
    const st = await spGetReport(region, token, reportId);
    if (st.processingStatus === 'DONE') { docId = st.reportDocumentId; break; }
    if (st.processingStatus === 'CANCELLED' || st.processingStatus === 'FATAL') {
      // CANCELLED thường = không có dữ liệu trong cửa sổ
      if (st.processingStatus === 'CANCELLED') return await ingest(c, [], reportId);
      throw new AmazonError(`Report ${st.processingStatus}`, 'amazon', false);
    }
    await sleep(10_000);
  }
  if (!docId) throw new AmazonError('Report chưa xong — thử lại sau', 'amazon', true, 120);

  await rpc('sync_job_progress', { p_job: j.id, p_stage: 'download', p_external_ref: reportId });
  const text = await spDownloadDocument(region, token, docId);
  await rpc('sync_job_progress', { p_job: j.id, p_stage: 'ingest' });
  let rows: RawRow[];
  switch (c.feed.feed_key) {
    case 'orders_daily': rows = mapOrders(text).filter((r) => r.order_date >= j.window_start && r.order_date.slice(0, 10) <= j.window_end); break;
    case 'returns': rows = mapReturns(text); break;
    case 'inventory_ledger': rows = mapInventory(text, new Date().toISOString().slice(0, 10)); break;
    case 'sales_traffic_daily': rows = mapSalesTraffic(text); break;
    default: throw new AmazonError(`feed ${c.feed.feed_key} chưa hỗ trợ`, 'parse', false);
  }
  return await ingest(c, rows, reportId);
}

// ---------------- Ads API pipeline ----------------
async function runAds(c: Claimed): Promise<Record<string, unknown>> {
  const cred = await loadCred(c.source.credential_ref) as AdsCred;
  const region = regionOf(c.source.config, c.tenant.marketplace);
  const profile = c.source.config.ads_profile_id || cred.profile_id;
  if (!profile) throw new AmazonError('Thiếu ads_profile_id (config) — chạy test kết nối để chọn profile', 'permission', false);
  const token = await lwaToken(cred);
  const j = c.job;
  let reportId = j.external_ref && j.stage && j.stage !== 'auth' && j.stage !== 'create_report' ? j.external_ref : null;
  const isSearch = c.feed.feed_key === 'search_terms';

  if (!reportId) {
    await rpc('sync_job_progress', { p_job: j.id, p_stage: 'create_report' });
    reportId = await adsCreateReport(region, cred, token, profile, {
      name: `vexim ${c.feed.feed_key} ${j.window_start}..${j.window_end}`, startDate: j.window_start, endDate: j.window_end,
      configuration: { adProduct: 'SPONSORED_PRODUCTS', groupBy: [isSearch ? 'searchTerm' : 'advertiser'], columns: isSearch ? ADS_SEARCH_TERM_COLUMNS : ADS_ADVERTISED_COLUMNS, reportTypeId: c.feed.amazon_report_type, timeUnit: 'DAILY', format: 'GZIP_JSON' },
    });
    await rpc('sync_job_progress', { p_job: j.id, p_stage: 'poll', p_external_ref: reportId });
  }
  let url: string | undefined;
  for (let i = 0; i < 8; i++) {
    const st = await adsGetReport(region, cred, token, profile, reportId);
    if (st.status === 'COMPLETED') { url = st.url; break; }
    if (st.status === 'FAILED') throw new AmazonError(`Ads report FAILED: ${st.failureReason ?? ''}`, 'amazon', false);
    await sleep(12_000);
  }
  if (!url) throw new AmazonError('Ads report chưa xong — thử lại sau', 'amazon', true, 180);
  await rpc('sync_job_progress', { p_job: j.id, p_stage: 'download' });
  const data = await adsDownload(url);
  await rpc('sync_job_progress', { p_job: j.id, p_stage: 'ingest' });
  const rows = isSearch ? mapAdsSearchTerms(data) : mapAdsAdvertised(data);
  return await ingest(c, rows, reportId);
}

async function processOne(): Promise<Record<string, unknown> | null> {
  const c = await rpc<Claimed | null>('claim_sync_job', { p_worker: WORKER, p_lease_seconds: 600 });
  if (!c) return null;
  const started = Date.now();
  try {
    const result = c.source.kind === 'sp_api' ? await runSp(c) : await runAds(c);
    const status = (result.status as string) === 'partial' ? 'partial' : 'succeeded';
    await rpc('finish_sync_job', { p_job: c.job.id, p_status: status, p_result: { ...result, ms: Date.now() - started } });
    return { job: c.job.id, feed: c.feed.feed_key, status, result };
  } catch (e) {
    const err = e instanceof AmazonError ? e : new AmazonError(String((e as Error)?.message ?? e), 'unknown' as never, false);
    const cls = e instanceof AmazonError ? e.cls : (/ingest_|Batch|dòng/.test(err.message) ? 'ingest' : 'unknown');
    await rpc('finish_sync_job', { p_job: c.job.id, p_status: 'failed', p_error: err.message.slice(0, 1000), p_error_class: cls, p_retryable: err.retryable, p_retry_after_seconds: err.retryAfter ?? null });
    return { job: c.job.id, feed: c.feed.feed_key, status: 'failed', error: err.message, cls, retryable: err.retryable };
  }
}

// ---------------- Auth helpers cho lời gọi từ UI ----------------
async function userCan(req: Request, tenant: string, perm: string): Promise<{ ok: boolean; uid?: string }> {
  const auth = req.headers.get('Authorization') ?? '';
  if (auth === `Bearer ${SERVICE_KEY}`) return { ok: true };
  const u = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: user } = await u.auth.getUser();
  if (!user?.user) return { ok: false };
  const { data } = await u.rpc('has_permission', { t: tenant, perm });
  return { ok: data === true, uid: user.user.id };
}

async function testConnection(sourceId: string): Promise<Record<string, unknown>> {
  const { data: s, error } = await admin.from('data_sources').select('id, tenant_id, kind, config, credential_ref, tenants(marketplace)').eq('id', sourceId).single();
  if (error || !s) throw new Error('Nguồn không tồn tại');
  const src = s as unknown as { id: string; tenant_id: string; kind: 'sp_api' | 'ads_api'; config: Record<string, string>; credential_ref: string | null; tenants: { marketplace: string } };
  if (!src.credential_ref) throw new Error('Chưa có credential');
  try {
    const cred = await loadCred(src.credential_ref);
    const region = regionOf(src.config, src.tenants.marketplace);
    const token = await lwaToken(cred);
    if (src.kind === 'sp_api') {
      // 1 lệnh đọc nhẹ: liệt kê report gần đây (không tạo gì)
      const mkId = marketplaceId(src.config, src.tenants.marketplace);
      const res = await fetch(`https://sellingpartnerapi-${region}.amazon.com/reports/2021-06-30/reports?reportTypes=GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL&marketplaceIds=${mkId}&pageSize=1`, { headers: { 'x-amz-access-token': token } });
      if (!res.ok) throw new AmazonError(`SP-API ${res.status}: ${(await res.text()).slice(0, 200)}`, res.status === 403 ? 'permission' : 'auth', false);
      await rpc('set_source_status', { p_source: src.id, p_status: 'connected', p_error: null, p_config_patch: { region, marketplace_id: mkId, verified_at: new Date().toISOString() } });
      return { ok: true, kind: 'sp_api', region, marketplace_id: mkId };
    }
    const profiles = await adsListProfiles(region, cred as AdsCred, token);
    const chosen = src.config.ads_profile_id || (cred as AdsCred).profile_id || (profiles.length === 1 ? String(profiles[0].profileId) : undefined);
    await rpc('set_source_status', { p_source: src.id, p_status: chosen ? 'connected' : 'error', p_error: chosen ? null : 'Nhiều profile — chọn ads_profile_id', p_config_patch: { region, ...(chosen ? { ads_profile_id: chosen } : {}), verified_at: new Date().toISOString() } });
    return { ok: !!chosen, kind: 'ads_api', region, profiles: profiles.map((p) => ({ id: String(p.profileId), country: p.countryCode, name: p.accountInfo?.name, type: p.accountInfo?.type })), ads_profile_id: chosen };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await rpc('set_source_status', { p_source: src.id, p_status: 'error', p_error: msg.slice(0, 500) });
    return { ok: false, error: msg };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return json({}, 204);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }
  const action = String(body.action ?? 'tick');
  const auth = req.headers.get('Authorization') ?? '';

  try {
    if (action === 'tick' || action === 'schedule') {
      if (auth !== `Bearer ${SERVICE_KEY}`) return json({ error: 'service role required' }, 401);
      let scheduled = 0;
      if (action === 'schedule' || body.schedule === true) scheduled = await rpc<number>('schedule_sync_jobs', {});
      const max = Math.min(Number(body.max_jobs ?? 3), 10);
      const results: unknown[] = [];
      for (let i = 0; i < max; i++) { const r = await processOne(); if (!r) break; results.push(r); }
      return json({ worker: WORKER, scheduled, processed: results.length, results });
    }
    if (action === 'store_credential') {
      const { source_id, credential } = body as { source_id: string; credential: Record<string, string> };
      const { data: s } = await admin.from('data_sources').select('id, tenant_id, kind, credential_ref').eq('id', source_id).single();
      if (!s) return json({ error: 'Nguồn không tồn tại' }, 404);
      const perm = await userCan(req, s.tenant_id, 'policy.edit');
      if (!perm.ok) return json({ error: 'Cần quyền policy.edit' }, 403);
      for (const k of ['client_id', 'client_secret', 'refresh_token']) if (!credential?.[k]) return json({ error: `Thiếu ${k}` }, 400);
      const ref = s.credential_ref || `${s.kind}:${s.tenant_id}:${s.id.slice(0, 8)}`;
      await rpc('connector_secret_put', { p_ref: ref, p_value: JSON.stringify({ client_id: credential.client_id, client_secret: credential.client_secret, refresh_token: credential.refresh_token, ...(credential.profile_id ? { profile_id: credential.profile_id } : {}) }), p_description: `Vexim ${s.kind} credential` });
      await admin.from('data_sources').update({ credential_ref: ref, status: 'not_connected', last_error: null }).eq('id', s.id);
      await admin.from('audit_log').insert({ tenant_id: s.tenant_id, actor_id: perm.uid ?? null, action: 'connector.credential_stored', entity_type: 'data_source', entity_id: s.id, payload: { credential_ref: ref, kind: s.kind } }).then(() => undefined, () => undefined);
      const test = await testConnection(s.id);
      return json({ ok: true, credential_ref: ref, test });
    }
    if (action === 'test_connection') {
      const { source_id } = body as { source_id: string };
      const { data: s } = await admin.from('data_sources').select('id, tenant_id').eq('id', source_id).single();
      if (!s) return json({ error: 'Nguồn không tồn tại' }, 404);
      const perm = await userCan(req, s.tenant_id, 'policy.edit');
      if (!perm.ok) return json({ error: 'Cần quyền policy.edit' }, 403);
      return json(await testConnection(s.id));
    }
    if (action === 'run_now') {
      // user có data.import: worker xử lý ngay tối đa 2 job (giảm chờ cron)
      const { tenant_id } = body as { tenant_id: string };
      const perm = await userCan(req, tenant_id, 'data.import');
      if (!perm.ok) return json({ error: 'Cần quyền data.import' }, 403);
      const results: unknown[] = [];
      for (let i = 0; i < 2; i++) { const r = await processOne(); if (!r) break; results.push(r); }
      return json({ processed: results.length, results });
    }
    return json({ error: `action không hỗ trợ: ${action}` }, 400);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
