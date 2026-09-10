-- ============================================================
-- 023 — PHASE 2: Read-only connectors (SP-API / Ads API) — hàng đợi + secret + worker hooks
-- Chạy SAU 022. Idempotent. Cần extension: vault (Supabase có sẵn), pg_net + pg_cron (tuỳ chọn, cho lịch tự động).
--   • sync_jobs: hàng đợi kéo dữ liệu (tenant × source × feed × cửa sổ ngày), retry/backoff, idempotent.
--   • Secret: CHỈ trong Vault; DB giữ credential_ref. RPC connector_secret_* chỉ service_role gọi được (Edge Function).
--   • Worker (Edge Function amazon-sync) claim job → gọi Amazon → ghi qua ingest_* (cùng hợp đồng CSV).
--   • KHÔNG có write-back: không hàm nào ở đây gọi API ghi của Amazon.
-- ============================================================

-- ------------------------------------------------------------
-- 1. data_feeds: bổ sung report type Ads API + cột kéo tự động
-- ------------------------------------------------------------
ALTER TABLE public.data_feeds ADD COLUMN IF NOT EXISTS connector_kind TEXT CHECK (connector_kind IN ('sp_api','ads_api'));
ALTER TABLE public.data_feeds ADD COLUMN IF NOT EXISTS lookback_days INT NOT NULL DEFAULT 1;   -- cửa sổ kéo mặc định mỗi lần chạy
UPDATE public.data_feeds SET connector_kind = 'sp_api',  amazon_report_type = 'GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL', lookback_days = 3  WHERE feed_key = 'orders_daily';
UPDATE public.data_feeds SET connector_kind = 'sp_api',  amazon_report_type = 'GET_SALES_AND_TRAFFIC_REPORT',                          lookback_days = 3  WHERE feed_key = 'sales_traffic_daily';
UPDATE public.data_feeds SET connector_kind = 'sp_api',  amazon_report_type = 'GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA',               lookback_days = 1  WHERE feed_key = 'inventory_ledger';
UPDATE public.data_feeds SET connector_kind = 'sp_api',  amazon_report_type = 'GET_FBA_FULFILLMENT_CUSTOMER_RETURNS_DATA',             lookback_days = 7  WHERE feed_key = 'returns';
UPDATE public.data_feeds SET connector_kind = 'ads_api', amazon_report_type = 'spAdvertisedProduct',                                   lookback_days = 7  WHERE feed_key = 'ads_daily';
UPDATE public.data_feeds SET connector_kind = 'ads_api', amazon_report_type = 'spSearchTerm',                                          lookback_days = 7  WHERE feed_key = 'search_terms';
-- promotions: chưa có API ổn định → lịch nhập tay có audit (giữ connector_kind NULL)

-- ------------------------------------------------------------
-- 2. sync_jobs — hàng đợi
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sync_jobs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  source_id       UUID NOT NULL REFERENCES public.data_sources(id) ON DELETE CASCADE,
  feed_key        TEXT NOT NULL REFERENCES public.data_feeds(feed_key),
  window_start    DATE NOT NULL,
  window_end      DATE NOT NULL,
  triggered_by    TEXT NOT NULL DEFAULT 'manual' CHECK (triggered_by IN ('manual','schedule','backfill','system')),
  status          TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','partial','failed','cancelled')),
  stage           TEXT,                       -- auth | create_report | poll | download | ingest
  external_ref    TEXT,                       -- reportId / reportDocumentId
  attempt         INT NOT NULL DEFAULT 0,
  max_attempts    INT NOT NULL DEFAULT 5,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_at       TIMESTAMPTZ,
  locked_by       TEXT,
  run_id          UUID REFERENCES public.ingestion_runs(id) ON DELETE SET NULL,
  batch_id        UUID REFERENCES public.ingest_batches(id) ON DELETE SET NULL,
  result          JSONB,
  last_error      TEXT,
  error_class     TEXT,                       -- auth | rate_limit | permission | amazon | parse | ingest | network | unknown
  created_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at     TIMESTAMPTZ,
  CHECK (window_end >= window_start)
);
CREATE INDEX IF NOT EXISTS idx_sync_jobs_queue ON public.sync_jobs(status, next_attempt_at) WHERE status IN ('queued','running');
CREATE INDEX IF NOT EXISTS idx_sync_jobs_tenant ON public.sync_jobs(tenant_id, created_at DESC);
-- 1 job mở cho mỗi (source, feed, cửa sổ) — enqueue trùng → trả job cũ
CREATE UNIQUE INDEX IF NOT EXISTS uq_sync_jobs_open ON public.sync_jobs(source_id, feed_key, window_start, window_end) WHERE status IN ('queued','running');

ALTER TABLE public.sync_jobs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sync_jobs_select ON public.sync_jobs;
CREATE POLICY sync_jobs_select ON public.sync_jobs FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));

-- ------------------------------------------------------------
-- 3. Secret trong Vault — chỉ service_role
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.connector_secret_put(p_ref TEXT, p_value TEXT, p_description TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sid UUID;
BEGIN
  IF p_ref IS NULL OR p_ref !~ '^[a-z0-9_:-]{6,120}$' THEN RAISE EXCEPTION 'credential_ref không hợp lệ'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault') THEN RAISE EXCEPTION 'Vault chưa bật (extension supabase_vault)'; END IF;
  SELECT id INTO sid FROM vault.secrets WHERE name = p_ref;
  IF sid IS NULL THEN PERFORM vault.create_secret(p_value, p_ref, p_description);
  ELSE PERFORM vault.update_secret(sid, p_value, p_ref, p_description); END IF;
END; $$;
CREATE OR REPLACE FUNCTION public.connector_secret_get(p_ref TEXT)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = p_ref LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION public.connector_secret_delete(p_ref TEXT)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM vault.secrets WHERE name = p_ref;
$$;
REVOKE ALL ON FUNCTION public.connector_secret_put(TEXT, TEXT, TEXT), public.connector_secret_get(TEXT), public.connector_secret_delete(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.connector_secret_put(TEXT, TEXT, TEXT), public.connector_secret_get(TEXT), public.connector_secret_delete(TEXT) TO service_role;

-- Có secret cho ref này không (không lộ giá trị) — authenticated dùng để hiển thị "đã lưu"
CREATE OR REPLACE FUNCTION public.connector_secret_exists(t UUID, p_ref TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(t, 'policy.edit') THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.data_sources WHERE tenant_id = t AND credential_ref = p_ref) THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM vault.secrets WHERE name = p_ref);
END; $$;
GRANT EXECUTE ON FUNCTION public.connector_secret_exists(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 4. Enqueue / backfill (authenticated, cần data.import)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enqueue_sync(p_source UUID, p_feed TEXT, p_start DATE, p_end DATE, p_trigger TEXT DEFAULT 'manual')
RETURNS public.sync_jobs LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.data_sources; f public.data_feeds; j public.sync_jobs;
BEGIN
  SELECT * INTO s FROM public.data_sources WHERE id = p_source;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Nguồn không tồn tại'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(s.tenant_id, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền (data.import)'; END IF;
  IF s.kind NOT IN ('sp_api','ads_api') THEN RAISE EXCEPTION 'Nguồn % không phải connector API', s.kind; END IF;
  IF NOT s.enabled THEN RAISE EXCEPTION 'Nguồn đang tắt'; END IF;
  IF s.credential_ref IS NULL THEN RAISE EXCEPTION 'Nguồn chưa có credential_ref — kết nối trước'; END IF;
  SELECT * INTO f FROM public.data_feeds WHERE feed_key = p_feed;
  IF f.feed_key IS NULL OR f.connector_kind IS DISTINCT FROM s.kind THEN RAISE EXCEPTION 'Feed % không do nguồn % cung cấp', p_feed, s.kind; END IF;
  IF NOT (p_feed = ANY(s.feeds)) THEN RAISE EXCEPTION 'Feed % chưa bật cho nguồn này', p_feed; END IF;
  IF p_end < p_start OR p_end > CURRENT_DATE THEN RAISE EXCEPTION 'Cửa sổ ngày không hợp lệ'; END IF;
  IF p_end - p_start > 30 THEN RAISE EXCEPTION 'Tối đa 31 ngày / job (Amazon giới hạn report) — dùng backfill_sync'; END IF;
  INSERT INTO public.sync_jobs (tenant_id, source_id, feed_key, window_start, window_end, triggered_by, created_by)
  VALUES (s.tenant_id, p_source, p_feed, p_start, p_end, p_trigger, auth.uid())
  ON CONFLICT (source_id, feed_key, window_start, window_end) WHERE status IN ('queued','running') DO UPDATE SET next_attempt_at = LEAST(sync_jobs.next_attempt_at, now())
  RETURNING * INTO j;
  RETURN j;
END; $$;
GRANT EXECUTE ON FUNCTION public.enqueue_sync(UUID, TEXT, DATE, DATE, TEXT) TO authenticated;

-- backfill 1 / 7 / 28 ngày: chia nhỏ theo feed (Sales&Traffic = 1 ngày/report; ads = 1 ngày/report; orders/returns = tối đa 7 ngày/report)
CREATE OR REPLACE FUNCTION public.backfill_sync(p_source UUID, p_feed TEXT, p_days INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.data_sources; step INT; d DATE; e DATE; n INT := 0; lag INT; last_day DATE;
BEGIN
  IF p_days NOT IN (1, 7, 28) THEN RAISE EXCEPTION 'p_days phải là 1, 7 hoặc 28'; END IF;
  SELECT * INTO s FROM public.data_sources WHERE id = p_source;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Nguồn không tồn tại'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(s.tenant_id, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền (data.import)'; END IF;
  SELECT settlement_lag_days INTO lag FROM public.data_feeds WHERE feed_key = p_feed;
  last_day := CURRENT_DATE - 1;                    -- dữ liệu hôm qua; ads sẽ được kéo lại nhờ lookback
  step := CASE WHEN p_feed IN ('sales_traffic_daily','ads_daily','search_terms') THEN 1 WHEN p_feed = 'inventory_ledger' THEN 1 ELSE 7 END;
  IF p_feed = 'inventory_ledger' THEN
    PERFORM public.enqueue_sync(p_source, p_feed, CURRENT_DATE, CURRENT_DATE, 'backfill'); RETURN jsonb_build_object('jobs', 1, 'note', 'tồn kho chỉ có snapshot hiện tại');
  END IF;
  d := last_day - p_days + 1;
  WHILE d <= last_day LOOP
    e := LEAST(d + step - 1, last_day);
    PERFORM public.enqueue_sync(p_source, p_feed, d, e, 'backfill');
    n := n + 1; d := e + 1;
  END LOOP;
  RETURN jsonb_build_object('jobs', n, 'from', last_day - p_days + 1, 'to', last_day, 'settlement_lag_days', COALESCE(lag, 0));
END; $$;
GRANT EXECUTE ON FUNCTION public.backfill_sync(UUID, TEXT, INT) TO authenticated;

-- Lịch: mỗi nguồn enabled+connected → 1 job/feed cho cửa sổ lookback (idempotent). Gọi bởi cron hoặc worker.
CREATE OR REPLACE FUNCTION public.schedule_sync_jobs()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s RECORD; f RECORD; n INT := 0; d0 DATE; d1 DATE;
BEGIN
  FOR s IN SELECT * FROM public.data_sources WHERE kind IN ('sp_api','ads_api') AND enabled AND status = 'connected' AND credential_ref IS NOT NULL LOOP
    FOR f IN SELECT * FROM public.data_feeds WHERE connector_kind = s.kind AND feed_key = ANY(s.feeds) LOOP
      d1 := CASE WHEN f.feed_key = 'inventory_ledger' THEN CURRENT_DATE ELSE CURRENT_DATE - 1 END;
      d0 := d1 - GREATEST(f.lookback_days, 1) + 1;
      IF f.feed_key IN ('sales_traffic_daily','ads_daily','search_terms') THEN
        -- 1 ngày / job
        WHILE d0 <= d1 LOOP
          BEGIN PERFORM public.enqueue_sync(s.id, f.feed_key, d0, d0, 'schedule'); n := n + 1; EXCEPTION WHEN others THEN NULL; END;
          d0 := d0 + 1;
        END LOOP;
      ELSE
        BEGIN PERFORM public.enqueue_sync(s.id, f.feed_key, d0, d1, 'schedule'); n := n + 1; EXCEPTION WHEN others THEN NULL; END;
      END IF;
    END LOOP;
  END LOOP;
  RETURN n;
END; $$;
REVOKE ALL ON FUNCTION public.schedule_sync_jobs() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_sync_jobs() TO service_role;

-- ------------------------------------------------------------
-- 5. Worker API (service_role): claim → progress → complete/fail
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_sync_job(p_worker TEXT, p_lease_seconds INT DEFAULT 600)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.sync_jobs; s public.data_sources; f public.data_feeds; t public.tenants;
BEGIN
  -- thu hồi lease quá hạn
  UPDATE public.sync_jobs SET status = 'queued', locked_at = NULL, locked_by = NULL, last_error = COALESCE(last_error, '') || ' [lease hết hạn]'
  WHERE status = 'running' AND locked_at < now() - make_interval(secs => p_lease_seconds);

  SELECT * INTO j FROM public.sync_jobs WHERE status = 'queued' AND next_attempt_at <= now()
  ORDER BY CASE triggered_by WHEN 'manual' THEN 0 WHEN 'schedule' THEN 1 ELSE 2 END, created_at
  LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF j.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.sync_jobs SET status = 'running', locked_at = now(), locked_by = p_worker, attempt = attempt + 1, stage = 'auth' WHERE id = j.id RETURNING * INTO j;
  SELECT * INTO s FROM public.data_sources WHERE id = j.source_id;
  SELECT * INTO f FROM public.data_feeds WHERE feed_key = j.feed_key;
  SELECT * INTO t FROM public.tenants WHERE id = j.tenant_id;
  RETURN jsonb_build_object(
    'job', to_jsonb(j),
    'source', jsonb_build_object('id', s.id, 'kind', s.kind, 'config', s.config, 'credential_ref', s.credential_ref),
    'feed', jsonb_build_object('feed_key', f.feed_key, 'import_kind', f.import_kind, 'amazon_report_type', f.amazon_report_type, 'settlement_lag_days', f.settlement_lag_days),
    'tenant', jsonb_build_object('id', t.id, 'marketplace', t.marketplace));
END; $$;

CREATE OR REPLACE FUNCTION public.sync_job_progress(p_job UUID, p_stage TEXT, p_external_ref TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.sync_jobs SET stage = p_stage, external_ref = COALESCE(p_external_ref, external_ref), locked_at = now() WHERE id = p_job AND status = 'running';
$$;

-- Hoàn tất: p_status succeeded|partial|failed; p_retryable → xếp lại với backoff (1,4,9,16,25 phút ×) nếu còn attempt
CREATE OR REPLACE FUNCTION public.finish_sync_job(p_job UUID, p_status TEXT, p_result JSONB DEFAULT NULL, p_error TEXT DEFAULT NULL, p_error_class TEXT DEFAULT NULL, p_retryable BOOLEAN DEFAULT false, p_retry_after_seconds INT DEFAULT NULL)
RETURNS public.sync_jobs LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.sync_jobs; delay INT;
BEGIN
  SELECT * INTO j FROM public.sync_jobs WHERE id = p_job FOR UPDATE;
  IF j.id IS NULL THEN RAISE EXCEPTION 'job không tồn tại'; END IF;
  IF p_status NOT IN ('succeeded','partial','failed') THEN RAISE EXCEPTION 'status không hợp lệ'; END IF;
  IF p_status = 'failed' AND p_retryable AND j.attempt < j.max_attempts THEN
    delay := COALESCE(p_retry_after_seconds, 60 * j.attempt * j.attempt);
    UPDATE public.sync_jobs SET status = 'queued', next_attempt_at = now() + make_interval(secs => delay), locked_at = NULL, locked_by = NULL,
      last_error = p_error, error_class = p_error_class, result = COALESCE(p_result, result) WHERE id = p_job RETURNING * INTO j;
  ELSE
    UPDATE public.sync_jobs SET status = p_status, finished_at = now(), locked_at = NULL, locked_by = NULL, last_error = p_error, error_class = p_error_class,
      result = COALESCE(p_result, result), run_id = COALESCE((p_result->>'run_id')::uuid, run_id), batch_id = COALESCE((p_result->>'batch_id')::uuid, batch_id)
    WHERE id = p_job RETURNING * INTO j;
    -- job thất bại hẳn vì auth/permission → đánh dấu nguồn lỗi (không tự tắt)
    IF p_status = 'failed' AND p_error_class IN ('auth','permission') THEN
      UPDATE public.data_sources SET status = 'error', last_error = p_error, last_run_at = now() WHERE id = j.source_id;
    ELSE
      UPDATE public.data_sources SET last_run_at = now(), last_error = CASE WHEN p_status = 'failed' THEN p_error ELSE NULL END WHERE id = j.source_id;
    END IF;
    -- job thất bại không có run → vẫn ghi ingestion_runs failed để freshness thấy
    IF p_status = 'failed' AND j.run_id IS NULL THEN
      INSERT INTO public.ingestion_runs (tenant_id, source_id, feed_key, status, triggered_by, window_start, window_end, errors, external_ref, attempt, started_at, finished_at)
      VALUES (j.tenant_id, j.source_id, j.feed_key, 'failed', j.triggered_by, j.window_start, j.window_end, jsonb_build_array(jsonb_build_object('row', 0, 'error', p_error)), j.external_ref, j.attempt, j.locked_at, now())
      RETURNING id INTO j.run_id;
      UPDATE public.sync_jobs SET run_id = j.run_id WHERE id = p_job;
    END IF;
  END IF;
  RETURN j;
END; $$;

-- Kết quả test kết nối (worker gọi sau khi thử LWA + 1 API read)
CREATE OR REPLACE FUNCTION public.set_source_status(p_source UUID, p_status TEXT, p_error TEXT DEFAULT NULL, p_config_patch JSONB DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_status NOT IN ('not_connected','connected','error','disabled') THEN RAISE EXCEPTION 'status không hợp lệ'; END IF;
  IF p_config_patch IS NOT NULL AND (p_config_patch ? 'refresh_token' OR p_config_patch ? 'client_secret' OR p_config_patch ? 'access_token') THEN RAISE EXCEPTION 'Không lưu secret trong config'; END IF;
  UPDATE public.data_sources SET status = p_status, last_error = p_error, last_run_at = now(), config = config || COALESCE(p_config_patch, '{}'::jsonb) WHERE id = p_source;
END; $$;

REVOKE ALL ON FUNCTION public.claim_sync_job(TEXT, INT), public.sync_job_progress(UUID, TEXT, TEXT), public.finish_sync_job(UUID, TEXT, JSONB, TEXT, TEXT, BOOLEAN, INT), public.set_source_status(UUID, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_sync_job(TEXT, INT), public.sync_job_progress(UUID, TEXT, TEXT), public.finish_sync_job(UUID, TEXT, JSONB, TEXT, TEXT, BOOLEAN, INT), public.set_source_status(UUID, TEXT, TEXT, JSONB) TO service_role;

-- Người dùng: huỷ job đang chờ; yêu cầu test kết nối (tạo job đặc biệt feed = NULL? → dùng bảng riêng đơn giản: connector_requests)
CREATE OR REPLACE FUNCTION public.cancel_sync_job(p_job UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.sync_jobs;
BEGIN
  SELECT * INTO j FROM public.sync_jobs WHERE id = p_job;
  IF j.id IS NULL THEN RAISE EXCEPTION 'job không tồn tại'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(j.tenant_id, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
  IF j.status <> 'queued' THEN RAISE EXCEPTION 'Chỉ huỷ được job đang chờ'; END IF;
  UPDATE public.sync_jobs SET status = 'cancelled', finished_at = now() WHERE id = p_job;
END; $$;
GRANT EXECUTE ON FUNCTION public.cancel_sync_job(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 6. ingest_* : cho phép service_role (worker) gọi với tenant bất kỳ — đã đúng vì auth.uid() NULL → bỏ kiểm quyền;
--    nhưng ingest_open ghi source_id = csv → cho phép truyền source_id
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_open(p_tenant UUID, p_kind TEXT, p_filename TEXT, p_file_hash TEXT, p_column_map JSONB DEFAULT NULL, p_source UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sp RECORD; b RECORD; mk TEXT; sid UUID;
BEGIN
  PERFORM public.ingest_assert_permission(p_tenant);
  IF p_kind = 'cogs' AND auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'cogs.write') THEN RAISE EXCEPTION 'Nhập giá vốn cần quyền cogs.write'; END IF;
  SELECT * INTO sp FROM public.ingest_feed_specs WHERE import_kind = p_kind;
  IF sp IS NULL THEN RAISE EXCEPTION 'Loại feed không hỗ trợ ingest server-side: %', p_kind; END IF;
  IF p_file_hash IS NULL OR length(p_file_hash) < 8 THEN RAISE EXCEPTION 'Thiếu file_hash'; END IF;
  SELECT marketplace INTO mk FROM public.tenants WHERE id = p_tenant;
  IF mk IS NULL THEN RAISE EXCEPTION 'Tenant không tồn tại'; END IF;
  IF p_source IS NOT NULL THEN
    IF auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'Chỉ worker được chỉ định source_id'; END IF;
    SELECT id INTO sid FROM public.data_sources WHERE id = p_source AND tenant_id = p_tenant;
    IF sid IS NULL THEN RAISE EXCEPTION 'source_id không thuộc tenant'; END IF;
  END IF;

  SELECT * INTO b FROM public.ingest_batches WHERE tenant_id = p_tenant AND import_kind = p_kind AND file_hash = p_file_hash AND status = 'committed';
  IF b.id IS NOT NULL THEN
    RETURN jsonb_build_object('batch_id', b.id, 'duplicate', true, 'status', b.status, 'committed_at', b.committed_at,
      'rows_inserted', b.rows_inserted, 'rows_updated', b.rows_updated, 'rows_skipped', b.rows_skipped);
  END IF;
  DELETE FROM public.ingest_batches WHERE tenant_id = p_tenant AND import_kind = p_kind AND file_hash = p_file_hash AND status IN ('open','validated','failed');

  sid := COALESCE(sid, public.ensure_csv_source(p_tenant));
  INSERT INTO public.ingest_batches (tenant_id, marketplace, import_kind, feed_key, schema_version, source_id, filename, file_hash, column_map, created_by)
  VALUES (p_tenant, mk, p_kind, sp.feed_key, sp.schema_version, sid, p_filename, p_file_hash, p_column_map, auth.uid())
  RETURNING * INTO b;
  RETURN jsonb_build_object('batch_id', b.id, 'duplicate', false, 'status', b.status, 'schema_version', b.schema_version, 'feed_key', b.feed_key);
END; $$;
GRANT EXECUTE ON FUNCTION public.ingest_open(UUID, TEXT, TEXT, TEXT, JSONB, UUID) TO authenticated, service_role;
DROP FUNCTION IF EXISTS public.ingest_open(UUID, TEXT, TEXT, TEXT, JSONB);

-- ingest_commit: triggered_by theo nguồn (api → 'schedule'/'manual' do worker set sau) — giữ nguyên; worker cập nhật run.triggered_by
CREATE OR REPLACE FUNCTION public.set_run_trigger(p_run UUID, p_trigger TEXT, p_external_ref TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.ingestion_runs SET triggered_by = p_trigger, external_ref = COALESCE(p_external_ref, external_ref) WHERE id = p_run;
$$;
REVOKE ALL ON FUNCTION public.set_run_trigger(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_run_trigger(UUID, TEXT, TEXT) TO service_role;

-- ------------------------------------------------------------
-- 7. Views cho UI
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_sync_jobs WITH (security_invoker = true) AS
SELECT j.id, j.tenant_id, j.source_id, s.kind AS source_kind, s.name AS source_name, j.feed_key, f.label AS feed_label, j.window_start, j.window_end, j.triggered_by, j.status, j.stage,
       j.attempt, j.max_attempts, j.next_attempt_at, j.last_error, j.error_class, j.run_id, j.batch_id, j.result, j.created_at, j.finished_at, j.external_ref
FROM public.sync_jobs j JOIN public.data_sources s ON s.id = j.source_id JOIN public.data_feeds f ON f.feed_key = j.feed_key;

-- Trạng thái worker/cron: không giả định. worker_last_seen từ job gần nhất được claim.
CREATE OR REPLACE FUNCTION public.connector_health(t UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE has_cron BOOLEAN; cron_st TEXT := 'unknown'; last_claim TIMESTAMPTZ; q INT; r INT; f INT; has_vault BOOLEAN; has_net BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO has_cron;
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault') INTO has_vault;
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') INTO has_net;
  IF has_cron THEN
    BEGIN
      EXECUTE $q$ SELECT CASE WHEN EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vexim_amazon_sync' AND active) THEN 'ok' ELSE 'missing' END $q$ INTO cron_st;
    EXCEPTION WHEN others THEN cron_st := 'unknown'; END;
  ELSE cron_st := 'missing'; END IF;
  SELECT MAX(locked_at) INTO last_claim FROM public.sync_jobs WHERE tenant_id = t OR t IS NULL;
  SELECT count(*) FILTER (WHERE status = 'queued'), count(*) FILTER (WHERE status = 'running'), count(*) FILTER (WHERE status = 'failed' AND finished_at > now() - interval '24 hours')
    INTO q, r, f FROM public.sync_jobs WHERE tenant_id = t;
  RETURN jsonb_build_object('cron_status', cron_st, 'vault_enabled', has_vault, 'pg_net_enabled', has_net,
    'worker_last_seen', last_claim, 'worker_status', CASE WHEN last_claim IS NULL THEN 'unknown' WHEN last_claim > now() - interval '30 minutes' THEN 'ok' ELSE 'stale' END,
    'queued', q, 'running', r, 'failed_24h', f, 'write_back_enabled', false);
END; $$;
GRANT EXECUTE ON FUNCTION public.connector_health(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 8. (Tuỳ chọn) pg_cron + pg_net: gọi Edge Function mỗi 10 phút. Chạy tay sau khi deploy function và đặt secret:
--    SELECT public.connector_secret_put('vexim:project_url', 'https://<ref>.supabase.co');
--    SELECT public.connector_secret_put('vexim:service_role_key', '<service_role key>');
--    SELECT public.install_sync_cron();
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.install_sync_cron(p_schedule TEXT DEFAULT '*/10 * * * *')
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN 'pg_cron chưa bật'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN RETURN 'pg_net chưa bật'; END IF;
  IF public.connector_secret_get('vexim:project_url') IS NULL OR public.connector_secret_get('vexim:service_role_key') IS NULL THEN RETURN 'thiếu secret vexim:project_url / vexim:service_role_key trong Vault'; END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vexim_amazon_sync') THEN PERFORM cron.unschedule('vexim_amazon_sync'); END IF;
  PERFORM cron.schedule('vexim_amazon_sync', p_schedule, $c$
    SELECT net.http_post(
      url := public.connector_secret_get('vexim:project_url') || '/functions/v1/amazon-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || public.connector_secret_get('vexim:service_role_key')),
      body := jsonb_build_object('action', 'tick', 'max_jobs', 5),
      timeout_milliseconds := 120000)
  $c$);
  RETURN 'ok';
END; $$;
REVOKE ALL ON FUNCTION public.install_sync_cron(TEXT) FROM PUBLIC, anon, authenticated;

-- Self-check
DO $$
BEGIN
  RAISE NOTICE '023 self-check: sync_jobs=% | feeds có connector=% (kỳ vọng 6) | vault=% | pg_cron=% | pg_net=%',
    (SELECT to_regclass('public.sync_jobs') IS NOT NULL), (SELECT count(*) FROM public.data_feeds WHERE connector_kind IS NOT NULL),
    (SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault')), (SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')), (SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net'));
END $$;
