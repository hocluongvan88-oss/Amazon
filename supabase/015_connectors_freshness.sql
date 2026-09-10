-- ============================================================
-- 015 — P0‑5: Connector abstraction + freshness
--   data_feeds (catalog)  ·  data_sources (per tenant)  ·  ingestion_runs
--   CSV import_jobs → ingestion_runs tự động  ·  v_data_freshness  ·  feed_is_fresh()
-- Xem docs/CONNECTOR_CONTRACT_v0.1.md. Chạy SAU 014. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Feed catalog (cố định, toàn hệ thống)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.data_feeds (
  feed_key               TEXT PRIMARY KEY,
  domain                 TEXT NOT NULL CHECK (domain IN ('data','finance','inventory','revenue','ads','voc')),
  label                  TEXT NOT NULL,
  sla_hours              INT  NOT NULL,          -- quá SLA → stale
  settlement_lag_days    INT  NOT NULL DEFAULT 0, -- ads: 3 (Amazon khuyến nghị 72h)
  amazon_report_type     TEXT,                    -- SP‑API/Ads report cho P2
  required_for_readiness BOOLEAN NOT NULL DEFAULT false,
  import_kind            TEXT,                    -- map sang import_jobs.kind (CSV)
  note                   TEXT
);
INSERT INTO public.data_feeds (feed_key, domain, label, sla_hours, settlement_lag_days, amazon_report_type, required_for_readiness, import_kind, note) VALUES
  ('catalog',             'data',      'Danh mục SKU',              168, 0, 'GET_MERCHANT_LISTINGS_ALL_DATA',                          true,  'catalog',   'ASIN, tên, giá, SKU nội bộ'),
  ('cogs',                'finance',   'Giá vốn (COGS)',            720, 0, NULL,                                                      true,  'cogs',      'Chỉ Finance; nguồn kế toán'),
  ('fees',                'finance',   'Phí FBA & referral',        720, 0, 'GET_FBA_ESTIMATED_FBA_FEES_TXT_DATA',                     false, 'fees',      NULL),
  ('inventory',           'inventory', 'Tồn kho FBA',               48,  0, 'GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA',                 true,  'inventory', 'Khả dụng + inbound'),
  ('orders_daily',        'revenue',   'Đơn hàng theo ngày',        36,  1, 'GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL',    true,  'orders',    'Bỏ Cancelled; múi giờ UTC'),
  ('sales_traffic_daily', 'revenue',   'Sales & Traffic theo ngày', 48,  1, 'GET_SALES_AND_TRAFFIC_REPORT',                            false, NULL,        'Cần role Brand Analytics; asinGranularity=CHILD, dateGranularity=DAY'),
  ('sales_30d',           'revenue',   'Doanh số 30 ngày',          168, 0, NULL,                                                      false, 'sales',     'Business Report export – fallback'),
  ('ads_daily',           'ads',       'Quảng cáo theo ngày',       96,  3, 'ADS_API_V3_SP_ADVERTISED_PRODUCT',                        false, 'ads',       'Restatement 1/7/28 ngày → lookback re‑pull'),
  ('reviews',             'voc',       'Review khách hàng',         168, 0, NULL,                                                      false, 'reviews',   'Không có API review chính thức; chỉ lắng nghe')
ON CONFLICT (feed_key) DO UPDATE SET domain = EXCLUDED.domain, label = EXCLUDED.label, sla_hours = EXCLUDED.sla_hours,
  settlement_lag_days = EXCLUDED.settlement_lag_days, amazon_report_type = EXCLUDED.amazon_report_type,
  required_for_readiness = EXCLUDED.required_for_readiness, import_kind = EXCLUDED.import_kind, note = EXCLUDED.note;

-- ------------------------------------------------------------
-- 2. data_sources — instance kết nối theo tenant
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.data_sources (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL CHECK (kind IN ('csv_manual','sp_api','ads_api')),
  name            TEXT NOT NULL,
  enabled         BOOLEAN NOT NULL DEFAULT true,
  feeds           TEXT[] NOT NULL DEFAULT '{}',          -- feed_key được nguồn này cung cấp
  config          JSONB NOT NULL DEFAULT '{}'::jsonb,    -- marketplace_id, region, ads_profile_id… (KHÔNG chứa secret)
  credential_ref  TEXT,                                  -- tên khoá trong Vault/secret; không bao giờ là secret
  schedule_cron   TEXT,                                  -- P2 scheduler
  status          TEXT NOT NULL DEFAULT 'not_connected' CHECK (status IN ('not_connected','connected','error','disabled')),
  last_run_at     TIMESTAMPTZ,
  last_error      TEXT,
  created_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, kind, name)
);
CREATE INDEX IF NOT EXISTS idx_data_sources_tenant ON public.data_sources(tenant_id, enabled);

-- Mỗi tenant có sẵn 1 nguồn csv_manual
CREATE OR REPLACE FUNCTION public.ensure_csv_source(t UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sid UUID;
BEGIN
  SELECT id INTO sid FROM public.data_sources WHERE tenant_id = t AND kind = 'csv_manual' LIMIT 1;
  IF sid IS NULL THEN
    INSERT INTO public.data_sources (tenant_id, kind, name, feeds, status)
    VALUES (t, 'csv_manual', 'Seller Central export (CSV)', ARRAY['catalog','cogs','fees','inventory','orders_daily','sales_30d','ads_daily','reviews'], 'connected')
    RETURNING id INTO sid;
  END IF;
  RETURN sid;
END; $$;
INSERT INTO public.data_sources (tenant_id, kind, name, feeds, status)
SELECT id, 'csv_manual', 'Seller Central export (CSV)', ARRAY['catalog','cogs','fees','inventory','orders_daily','sales_30d','ads_daily','reviews'], 'connected'
FROM public.tenants t WHERE NOT EXISTS (SELECT 1 FROM public.data_sources s WHERE s.tenant_id = t.id AND s.kind = 'csv_manual');
-- tenant mới → tự có nguồn CSV
CREATE OR REPLACE FUNCTION public.tenant_defaults_015() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM public.ensure_csv_source(NEW.id); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_tenant_defaults_015 ON public.tenants;
CREATE TRIGGER trg_tenant_defaults_015 AFTER INSERT ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.tenant_defaults_015();

-- ------------------------------------------------------------
-- 3. ingestion_runs — mỗi lần lấy dữ liệu (bất kỳ nguồn nào)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ingestion_runs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  source_id        UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  feed_key         TEXT NOT NULL REFERENCES public.data_feeds(feed_key),
  status           TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','partial','failed','cancelled')),
  triggered_by     TEXT NOT NULL DEFAULT 'manual' CHECK (triggered_by IN ('manual','schedule','backfill','system')),
  window_start     DATE,
  window_end       DATE,
  rows_total       INT NOT NULL DEFAULT 0,
  rows_ok          INT NOT NULL DEFAULT 0,
  rows_failed      INT NOT NULL DEFAULT 0,
  errors           JSONB,
  external_ref     TEXT,                    -- SP‑API reportId / Ads reportId / filename
  idempotency_key  TEXT,
  import_job_id    UUID REFERENCES public.import_jobs(id) ON DELETE SET NULL,
  attempt          INT NOT NULL DEFAULT 1,
  started_at       TIMESTAMPTZ,
  finished_at      TIMESTAMPTZ,
  duration_ms      INT,
  created_by       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_runs_tenant_feed ON public.ingestion_runs(tenant_id, feed_key, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_runs_status ON public.ingestion_runs(status) WHERE status IN ('queued','running');
CREATE UNIQUE INDEX IF NOT EXISTS uq_runs_idem ON public.ingestion_runs(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.ingestion_run_touch() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN NEW.created_by := COALESCE(NEW.created_by, auth.uid()); END IF;
  IF NEW.status = 'running' AND NEW.started_at IS NULL THEN NEW.started_at := now(); END IF;
  IF NEW.status IN ('succeeded','partial','failed','cancelled') AND NEW.finished_at IS NULL THEN
    NEW.finished_at := now();
    NEW.duration_ms := EXTRACT(EPOCH FROM (now() - COALESCE(NEW.started_at, NEW.created_at))) * 1000;
  END IF;
  IF NEW.status IN ('succeeded','partial','failed') AND NEW.source_id IS NOT NULL THEN
    UPDATE public.data_sources SET last_run_at = now(), last_error = CASE WHEN NEW.status = 'failed' THEN left(COALESCE(NEW.errors::text,'lỗi'), 500) ELSE NULL END,
      status = CASE WHEN NEW.status = 'failed' THEN 'error' ELSE 'connected' END, updated_at = now() WHERE id = NEW.source_id;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_ingestion_runs_touch ON public.ingestion_runs;
CREATE TRIGGER trg_ingestion_runs_touch BEFORE INSERT OR UPDATE ON public.ingestion_runs FOR EACH ROW EXECUTE FUNCTION public.ingestion_run_touch();

-- CSV import_jobs → ingestion_runs (CSV là 1 connector, không phải đường riêng)
CREATE OR REPLACE FUNCTION public.import_job_to_run() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE fk TEXT; sid UUID; st TEXT;
BEGIN
  SELECT feed_key INTO fk FROM public.data_feeds WHERE import_kind = NEW.kind LIMIT 1;
  IF fk IS NULL THEN RETURN NEW; END IF;
  sid := public.ensure_csv_source(NEW.tenant_id);
  st := CASE WHEN NEW.rows_ok = 0 AND NEW.rows_failed > 0 THEN 'failed' WHEN NEW.rows_failed > 0 THEN 'partial' ELSE 'succeeded' END;
  INSERT INTO public.ingestion_runs (tenant_id, source_id, feed_key, status, triggered_by, rows_total, rows_ok, rows_failed, errors, external_ref, import_job_id, started_at, created_by)
  VALUES (NEW.tenant_id, sid, fk, st, 'manual', NEW.rows_total, NEW.rows_ok, NEW.rows_failed, NEW.errors, NEW.filename, NEW.id, NEW.created_at, NEW.created_by);
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_import_job_to_run ON public.import_jobs;
CREATE TRIGGER trg_import_job_to_run AFTER INSERT ON public.import_jobs FOR EACH ROW EXECUTE FUNCTION public.import_job_to_run();

-- Backfill run từ import_jobs cũ
INSERT INTO public.ingestion_runs (tenant_id, source_id, feed_key, status, triggered_by, rows_total, rows_ok, rows_failed, errors, external_ref, import_job_id, started_at, finished_at, created_by, created_at)
SELECT j.tenant_id, public.ensure_csv_source(j.tenant_id), f.feed_key,
       CASE WHEN j.rows_ok = 0 AND j.rows_failed > 0 THEN 'failed' WHEN j.rows_failed > 0 THEN 'partial' ELSE 'succeeded' END,
       'manual', j.rows_total, j.rows_ok, j.rows_failed, j.errors, j.filename, j.id, j.created_at, j.created_at, j.created_by, j.created_at
FROM public.import_jobs j JOIN public.data_feeds f ON f.import_kind = j.kind
WHERE NOT EXISTS (SELECT 1 FROM public.ingestion_runs r WHERE r.import_job_id = j.id);

-- import_jobs: thêm 'reviews' vào kind nếu chưa có (UI đã dùng)
ALTER TABLE public.import_jobs DROP CONSTRAINT IF EXISTS import_jobs_kind_check;
ALTER TABLE public.import_jobs ADD CONSTRAINT import_jobs_kind_check
  CHECK (kind IN ('catalog','cogs','sales','inventory','fees','orders','ads','reviews'));

-- ------------------------------------------------------------
-- 4. Freshness — last_data_date lấy từ dữ liệu thật, không chỉ từ log
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_data_freshness WITH (security_invoker = true) AS
WITH tf AS (
  SELECT t.id AS tenant_id, f.* FROM public.tenants t CROSS JOIN public.data_feeds f
  WHERE t.id IN (SELECT public.my_tenant_ids())
),
last_run AS (
  SELECT DISTINCT ON (tenant_id, feed_key) tenant_id, feed_key, id AS run_id, status, finished_at, rows_ok, rows_failed, source_id
  FROM public.ingestion_runs WHERE status IN ('succeeded','partial','failed') ORDER BY tenant_id, feed_key, finished_at DESC
),
last_ok AS (
  SELECT tenant_id, feed_key, MAX(finished_at) AS last_success_at FROM public.ingestion_runs WHERE status IN ('succeeded','partial') GROUP BY tenant_id, feed_key
),
data_dates AS (
  SELECT tf.tenant_id, tf.feed_key,
    CASE tf.feed_key
      WHEN 'orders_daily'        THEN (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.units IS NOT NULL)
      WHEN 'sales_traffic_daily' THEN (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.sessions IS NOT NULL)
      WHEN 'ads_daily'           THEN (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.ad_spend IS NOT NULL)
      WHEN 'inventory'           THEN (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.inventory_qty IS NOT NULL)
      WHEN 'cogs'                THEN (SELECT MAX(created_at)::date FROM public.cogs_history c WHERE c.tenant_id = tf.tenant_id)
      WHEN 'fees'                THEN (SELECT MAX(fee_updated_at)::date FROM public.amazon_skus k WHERE k.tenant_id = tf.tenant_id)
      WHEN 'catalog'             THEN (SELECT MAX(updated_at)::date FROM public.amazon_skus k WHERE k.tenant_id = tf.tenant_id)
      WHEN 'sales_30d'           THEN (SELECT MAX(updated_at)::date FROM public.amazon_skus k WHERE k.tenant_id = tf.tenant_id AND k.revenue_last_30d IS NOT NULL)
      WHEN 'reviews'             THEN (SELECT MAX(created_at)::date FROM public.raw_reviews r WHERE r.tenant_id = tf.tenant_id)
    END AS last_data_date
  FROM tf
)
SELECT tf.tenant_id, tf.feed_key, tf.domain, tf.label, tf.sla_hours, tf.settlement_lag_days, tf.required_for_readiness,
       lo.last_success_at, lr.status AS last_run_status, lr.rows_ok AS last_rows_ok, lr.rows_failed AS last_rows_failed, lr.run_id AS last_run_id,
       dd.last_data_date,
       -- ngày dữ liệu "nên có" = hôm nay − settlement lag − 1 (dữ liệu hôm qua)
       (CURRENT_DATE - tf.settlement_lag_days - 1) AS expected_through,
       EXTRACT(EPOCH FROM (now() - COALESCE(lo.last_success_at, dd.last_data_date::timestamptz))) / 3600 AS age_hours,
       CASE
         WHEN lo.last_success_at IS NULL AND dd.last_data_date IS NULL THEN 'missing'
         WHEN EXTRACT(EPOCH FROM (now() - COALESCE(lo.last_success_at, dd.last_data_date::timestamptz))) / 3600 > tf.sla_hours THEN 'stale'
         WHEN dd.last_data_date IS NOT NULL AND tf.settlement_lag_days >= 0 AND tf.domain IN ('revenue','ads') AND dd.last_data_date < (CURRENT_DATE - tf.settlement_lag_days - 1) - (tf.sla_hours / 24) THEN 'stale'
         ELSE 'fresh'
       END AS status,
       (SELECT s.kind FROM public.data_sources s WHERE s.id = lr.source_id) AS source_kind
FROM tf
LEFT JOIN last_run lr ON lr.tenant_id = tf.tenant_id AND lr.feed_key = tf.feed_key
LEFT JOIN last_ok  lo ON lo.tenant_id = tf.tenant_id AND lo.feed_key = tf.feed_key
LEFT JOIN data_dates dd ON dd.tenant_id = tf.tenant_id AND dd.feed_key = tf.feed_key;

CREATE OR REPLACE FUNCTION public.feed_is_fresh(t UUID, p_feed TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH f AS (SELECT * FROM public.data_feeds WHERE feed_key = p_feed),
  lo AS (SELECT MAX(finished_at) AS at FROM public.ingestion_runs WHERE tenant_id = t AND feed_key = p_feed AND status IN ('succeeded','partial'))
  SELECT COALESCE((SELECT at FROM lo) > now() - make_interval(hours => (SELECT sla_hours FROM f)), false);
$$;
GRANT EXECUTE ON FUNCTION public.feed_is_fresh(UUID, TEXT) TO authenticated;

-- Tóm tắt cho Dashboard/Control Room
CREATE OR REPLACE FUNCTION public.freshness_summary(t UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH v AS (
    SELECT f.feed_key, f.label, f.required_for_readiness,
      (SELECT MAX(finished_at) FROM public.ingestion_runs r WHERE r.tenant_id = t AND r.feed_key = f.feed_key AND r.status IN ('succeeded','partial')) AS last_ok,
      f.sla_hours
    FROM public.data_feeds f
  ), s AS (
    SELECT feed_key, label, required_for_readiness,
      CASE WHEN last_ok IS NULL THEN 'missing' WHEN last_ok < now() - make_interval(hours => sla_hours) THEN 'stale' ELSE 'fresh' END AS status,
      ROUND(EXTRACT(EPOCH FROM (now() - last_ok)) / 3600) AS age_hours
    FROM v
  )
  SELECT jsonb_build_object(
    'fresh',   (SELECT count(*) FROM s WHERE status = 'fresh'),
    'stale',   (SELECT count(*) FROM s WHERE status = 'stale'),
    'missing', (SELECT count(*) FROM s WHERE status = 'missing'),
    'required_ok', (SELECT bool_and(status = 'fresh') FROM s WHERE required_for_readiness),
    'problems', (SELECT COALESCE(jsonb_agg(jsonb_build_object('feed', feed_key, 'label', label, 'status', status, 'age_hours', age_hours, 'required', required_for_readiness) ORDER BY required_for_readiness DESC, status), '[]'::jsonb) FROM s WHERE status <> 'fresh')
  );
$$;
GRANT EXECUTE ON FUNCTION public.freshness_summary(UUID) TO authenticated;

-- Control room: thêm freshness
CREATE OR REPLACE FUNCTION public.asin_control_room_v2(p_sku UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE base JSONB; t UUID; fr JSONB;
BEGIN
  base := public.asin_control_room(p_sku);
  IF base IS NULL THEN RETURN NULL; END IF;
  SELECT tenant_id INTO t FROM public.amazon_skus WHERE id = p_sku;
  fr := public.freshness_summary(t);
  base := base || jsonb_build_object('freshness', fr);
  IF NOT COALESCE((fr->>'required_ok')::boolean, false) THEN
    base := jsonb_set(base, '{signals}', (base->'signals') || jsonb_build_object('level','high','msg', format('Dữ liệu bắt buộc chưa tươi: %s', (SELECT string_agg(p->>'label', ', ') FROM jsonb_array_elements(fr->'problems') p WHERE (p->>'required')::boolean))));
  END IF;
  RETURN base;
END; $$;
GRANT EXECUTE ON FUNCTION public.asin_control_room_v2(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 5. Quản lý nguồn (RPC; secret không bao giờ đi qua đây)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_data_source(t UUID, p_kind TEXT, p_name TEXT, p_feeds TEXT[], p_config JSONB DEFAULT '{}'::jsonb, p_credential_ref TEXT DEFAULT NULL, p_enabled BOOLEAN DEFAULT true)
RETURNS public.data_sources LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.data_sources;
BEGIN
  IF NOT public.has_permission(t, 'policy.edit') THEN RAISE EXCEPTION 'Cần quyền policy.edit để quản lý nguồn dữ liệu'; END IF;
  IF p_config ? 'refresh_token' OR p_config ? 'client_secret' OR p_config ? 'access_token' THEN RAISE EXCEPTION 'Không lưu secret trong config — dùng credential_ref (Vault)'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_feeds) f WHERE f NOT IN (SELECT feed_key FROM public.data_feeds)) THEN RAISE EXCEPTION 'feed không hợp lệ'; END IF;
  INSERT INTO public.data_sources (tenant_id, kind, name, feeds, config, credential_ref, enabled, status, created_by)
  VALUES (t, p_kind, p_name, p_feeds, p_config, p_credential_ref, p_enabled, CASE WHEN p_kind = 'csv_manual' THEN 'connected' ELSE 'not_connected' END, auth.uid())
  ON CONFLICT (tenant_id, kind, name) DO UPDATE SET feeds = EXCLUDED.feeds, config = EXCLUDED.config, credential_ref = EXCLUDED.credential_ref, enabled = EXCLUDED.enabled, updated_at = now()
  RETURNING * INTO s;
  RETURN s;
END; $$;
GRANT EXECUTE ON FUNCTION public.upsert_data_source(UUID, TEXT, TEXT, TEXT[], JSONB, TEXT, BOOLEAN) TO authenticated;

-- ------------------------------------------------------------
-- 6. RLS + audit
-- ------------------------------------------------------------
ALTER TABLE public.data_feeds      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_sources    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingestion_runs  ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS feeds_select ON public.data_feeds;
DROP POLICY IF EXISTS ds_select ON public.data_sources; DROP POLICY IF EXISTS ds_write ON public.data_sources;
DROP POLICY IF EXISTS runs_select ON public.ingestion_runs; DROP POLICY IF EXISTS runs_insert ON public.ingestion_runs; DROP POLICY IF EXISTS runs_update ON public.ingestion_runs;
CREATE POLICY feeds_select ON public.data_feeds FOR SELECT TO authenticated USING (true);
CREATE POLICY ds_select ON public.data_sources FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY ds_write  ON public.data_sources FOR UPDATE TO authenticated USING (public.has_permission(tenant_id, 'policy.edit')) WITH CHECK (public.has_permission(tenant_id, 'policy.edit'));
CREATE POLICY runs_select ON public.ingestion_runs FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY runs_insert ON public.ingestion_runs FOR INSERT TO authenticated WITH CHECK (public.has_permission(tenant_id, 'data.import'));
CREATE POLICY runs_update ON public.ingestion_runs FOR UPDATE TO authenticated USING (public.has_permission(tenant_id, 'data.import')) WITH CHECK (public.has_permission(tenant_id, 'data.import'));
-- credential_ref chỉ là tên khoá; vẫn ẩn với người không có policy.edit qua view
CREATE OR REPLACE VIEW public.v_data_sources WITH (security_invoker = true) AS
SELECT id, tenant_id, kind, name, enabled, feeds, config, status, last_run_at, last_error, schedule_cron, created_at,
       CASE WHEN public.has_permission(tenant_id, 'policy.edit') THEN credential_ref END AS credential_ref
FROM public.data_sources;

DROP TRIGGER IF EXISTS trg_data_sources_audit ON public.data_sources;
CREATE TRIGGER trg_data_sources_audit AFTER INSERT OR UPDATE OR DELETE ON public.data_sources FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- Kiểm tra nhanh
-- SELECT feed_key, status, age_hours, last_data_date, expected_through FROM public.v_data_freshness ORDER BY status, feed_key;
