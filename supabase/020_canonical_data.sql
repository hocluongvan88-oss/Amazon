-- ============================================================
-- 020 — PHASE 1a: Canonical data model
-- Chạy SAU 019. Idempotent.
--   Bảng canonical tenant + marketplace scoped, natural key unique, source_record_hash.
--   RLS: CHỈ SELECT theo tenant. Ghi CHỈ qua RPC ingest_* (021) — không có policy INSERT/UPDATE.
--   sku_daily_snapshots được DERIVE từ canonical (derive_snapshots) → dashboard cũ không vỡ.
-- ============================================================

-- ------------------------------------------------------------
-- 1. orders — mỗi dòng = 1 order line (order × ASIN × SKU)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace         TEXT NOT NULL,
  order_id            TEXT NOT NULL,
  order_date          DATE NOT NULL,
  status              TEXT,                      -- Pending/Unshipped/Shipped/Cancelled… (nguyên văn Amazon, lower)
  is_cancelled        BOOLEAN NOT NULL DEFAULT false,
  fulfillment_channel TEXT,                      -- AFN/MFN
  asin                TEXT NOT NULL,
  sku                 TEXT NOT NULL DEFAULT '',
  quantity            INT NOT NULL CHECK (quantity >= 0),
  item_sales          NUMERIC(14,2),             -- tiền hàng của dòng (không phải đơn giá)
  currency            TEXT NOT NULL DEFAULT 'USD',
  source_id           UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash  TEXT NOT NULL,
  ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, marketplace, order_id, asin, sku)
);
CREATE INDEX IF NOT EXISTS idx_orders_tenant_date ON public.orders(tenant_id, order_date DESC);
CREATE INDEX IF NOT EXISTS idx_orders_tenant_asin_date ON public.orders(tenant_id, asin, order_date DESC);

-- ------------------------------------------------------------
-- 2. returns / refunds
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.returns (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace         TEXT NOT NULL,
  order_id            TEXT,
  return_date         DATE NOT NULL,
  asin                TEXT NOT NULL,
  sku                 TEXT NOT NULL DEFAULT '',
  quantity            INT NOT NULL CHECK (quantity >= 0),
  reason              TEXT,                      -- mã lý do Amazon (DEFECTIVE, NOT_AS_DESCRIBED…)
  customer_comment    TEXT,
  refund_amount       NUMERIC(14,2),
  currency            TEXT NOT NULL DEFAULT 'USD',
  disposition         TEXT,                      -- SELLABLE / DAMAGED / CUSTOMER_DAMAGED / DEFECTIVE…
  status              TEXT,
  return_ref          TEXT,                      -- LPN / RMA nếu có
  source_id           UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash  TEXT NOT NULL,
  ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, source_record_hash)        -- không có id ổn định trong report → khoá theo hash nội dung
);
CREATE INDEX IF NOT EXISTS idx_returns_tenant_date ON public.returns(tenant_id, return_date DESC);
CREATE INDEX IF NOT EXISTS idx_returns_tenant_asin ON public.returns(tenant_id, asin, return_date DESC);

-- ------------------------------------------------------------
-- 3. Ads dimension + fact
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ad_campaigns (
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace   TEXT NOT NULL,
  campaign_key  TEXT NOT NULL,                   -- campaign_id nếu có, nếu không = tên
  campaign_id   TEXT,
  name          TEXT,
  campaign_type TEXT,                            -- SP/SB/SD
  targeting     TEXT,                            -- auto/manual
  status        TEXT,
  daily_budget  NUMERIC(12,2),
  start_date    DATE,
  end_date      DATE,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, marketplace, campaign_key)
);
CREATE TABLE IF NOT EXISTS public.ad_groups (
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace   TEXT NOT NULL,
  campaign_key  TEXT NOT NULL,
  ad_group_key  TEXT NOT NULL,
  ad_group_id   TEXT,
  name          TEXT,
  status        TEXT,
  default_bid   NUMERIC(12,2),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, marketplace, campaign_key, ad_group_key)
);
CREATE TABLE IF NOT EXISTS public.ad_keywords (
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace   TEXT NOT NULL,
  campaign_key  TEXT NOT NULL,
  ad_group_key  TEXT NOT NULL,
  keyword_key   TEXT NOT NULL,                   -- keyword_id nếu có, nếu không = text|match
  keyword_id    TEXT,
  keyword_text  TEXT,
  match_type    TEXT,
  bid           NUMERIC(12,2),
  state         TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, marketplace, campaign_key, ad_group_key, keyword_key)
);
CREATE TABLE IF NOT EXISTS public.ad_daily (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace        TEXT NOT NULL,
  date               DATE NOT NULL,
  level              TEXT NOT NULL CHECK (level IN ('campaign','ad_group','keyword','asin')),
  campaign_key       TEXT NOT NULL DEFAULT '',
  ad_group_key       TEXT NOT NULL DEFAULT '',
  keyword_key        TEXT NOT NULL DEFAULT '',
  asin               TEXT NOT NULL DEFAULT '',
  impressions        INT,
  clicks             INT,
  spend              NUMERIC(12,2),
  orders             INT,
  sales              NUMERIC(14,2),
  attribution_days   INT NOT NULL DEFAULT 7,
  source_id          UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash TEXT NOT NULL,
  ingested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, marketplace, date, level, campaign_key, ad_group_key, keyword_key, asin)
);
CREATE INDEX IF NOT EXISTS idx_ad_daily_tenant_date ON public.ad_daily(tenant_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_ad_daily_asin ON public.ad_daily(tenant_id, asin, date DESC) WHERE asin <> '';

-- ------------------------------------------------------------
-- 4. search_terms (Sponsored Products search term report)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.search_terms (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace        TEXT NOT NULL,
  date               DATE NOT NULL,
  campaign_key       TEXT NOT NULL DEFAULT '',
  ad_group_key       TEXT NOT NULL DEFAULT '',
  keyword_key        TEXT NOT NULL DEFAULT '',
  keyword_text       TEXT,
  match_type         TEXT NOT NULL DEFAULT '',
  search_term        TEXT NOT NULL,
  asin               TEXT NOT NULL DEFAULT '',   -- advertised ASIN nếu report có
  impressions        INT,
  clicks             INT,
  spend              NUMERIC(12,2),
  orders             INT,
  sales              NUMERIC(14,2),
  source_id          UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash TEXT NOT NULL,
  ingested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, marketplace, date, campaign_key, ad_group_key, keyword_key, match_type, search_term, asin)
);
CREATE INDEX IF NOT EXISTS idx_search_terms_tenant_date ON public.search_terms(tenant_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_search_terms_term ON public.search_terms(tenant_id, search_term);

-- ------------------------------------------------------------
-- 5. promotions (coupon / deal / promotion / prime exclusive) — lịch có audit
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.promotions (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace        TEXT NOT NULL,
  promo_id           TEXT NOT NULL,
  promo_type         TEXT NOT NULL CHECK (promo_type IN ('coupon','lightning_deal','best_deal','promotion','prime_exclusive','other')),
  name               TEXT,
  asins              TEXT[] NOT NULL DEFAULT '{}',
  start_at           DATE NOT NULL,
  end_at             DATE,
  discount_type      TEXT,                       -- percent | amount
  discount_value     NUMERIC(12,2),
  budget             NUMERIC(12,2),
  status             TEXT,
  margin_note        TEXT,
  source             TEXT NOT NULL DEFAULT 'csv' CHECK (source IN ('csv','manual','api')),
  source_id          UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash TEXT NOT NULL,
  ingested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, marketplace, promo_id),
  CHECK (end_at IS NULL OR end_at >= start_at)
);
CREATE INDEX IF NOT EXISTS idx_promotions_tenant_window ON public.promotions(tenant_id, start_at, end_at);

-- ------------------------------------------------------------
-- 6. traffic_daily (Business report / Sales & Traffic by child ASIN)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.traffic_daily (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace           TEXT NOT NULL,
  date                  DATE NOT NULL,
  asin                  TEXT NOT NULL,
  sessions              INT,
  page_views            INT,
  units_ordered         INT,
  ordered_product_sales NUMERIC(14,2),
  buy_box_pct           NUMERIC(6,2),
  unit_session_pct      NUMERIC(6,2),
  impressions           INT,                     -- SQP/Brand Analytics nếu có
  clicks                INT,
  source_id             UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash    TEXT NOT NULL,
  ingested_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, marketplace, date, asin)
);
CREATE INDEX IF NOT EXISTS idx_traffic_daily_tenant_date ON public.traffic_daily(tenant_id, date DESC);

-- ------------------------------------------------------------
-- 7. inventory_ledger (FBA inventory theo ngày × ASIN × SKU × FC)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_ledger (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace        TEXT NOT NULL,
  date               DATE NOT NULL,
  asin               TEXT NOT NULL,
  sku                TEXT NOT NULL DEFAULT '',
  fc                 TEXT NOT NULL DEFAULT '',
  available          INT,
  reserved           INT,
  inbound            INT,
  unfulfillable      INT,
  stranded           INT,
  aged_90            INT,
  aged_180           INT,
  aged_270           INT,
  aged_365           INT,
  source_id          UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  source_record_hash TEXT NOT NULL,
  ingested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, marketplace, date, asin, sku, fc)
);
CREATE INDEX IF NOT EXISTS idx_inventory_ledger_tenant_date ON public.inventory_ledger(tenant_id, date DESC);

-- ------------------------------------------------------------
-- 8. RLS: chỉ SELECT theo tenant; không policy ghi (RPC SECURITY DEFINER)
-- ------------------------------------------------------------
DO $$
DECLARE tb TEXT;
BEGIN
  FOREACH tb IN ARRAY ARRAY['orders','returns','ad_campaigns','ad_groups','ad_keywords','ad_daily','search_terms','promotions','traffic_daily','inventory_ledger'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tb);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', tb || '_select', tb);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()))', tb || '_select', tb);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated ON public.%I', tb, tb);
    EXECUTE format('CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', tb, tb);
  END LOOP;
END $$;

-- ------------------------------------------------------------
-- 9. data_feeds: feed mới + import_kind cho traffic
-- ------------------------------------------------------------
INSERT INTO public.data_feeds (feed_key, domain, label, sla_hours, settlement_lag_days, amazon_report_type, required_for_readiness, import_kind, note) VALUES
  ('returns',          'revenue',   'Trả hàng / hoàn tiền',        72,  2, 'GET_FBA_FULFILLMENT_CUSTOMER_RETURNS_DATA',      false, 'returns',          'FBA Customer Returns report; hoàn tiền từ Finances'),
  ('search_terms',     'ads',       'Search term (SP)',            96,  3, 'ADS_API_V3_SP_SEARCH_TERM',                      false, 'search_terms',     'Sponsored Products search term report, Daily'),
  ('promotions',       'revenue',   'Khuyến mãi / coupon / deal',  168, 0, NULL,                                             false, 'promotions',       'Lịch nhập tay có audit; API P2 nếu khả thi'),
  ('inventory_ledger', 'inventory', 'Sổ tồn kho FBA chi tiết',     48,  0, 'GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA',        false, 'inventory_ledger', 'available/reserved/inbound/unfulfillable/aged')
ON CONFLICT (feed_key) DO UPDATE SET domain = EXCLUDED.domain, label = EXCLUDED.label, sla_hours = EXCLUDED.sla_hours,
  settlement_lag_days = EXCLUDED.settlement_lag_days, amazon_report_type = EXCLUDED.amazon_report_type,
  required_for_readiness = EXCLUDED.required_for_readiness, import_kind = EXCLUDED.import_kind, note = EXCLUDED.note;
UPDATE public.data_feeds SET import_kind = 'traffic' WHERE feed_key = 'sales_traffic_daily';

ALTER TABLE public.import_jobs DROP CONSTRAINT IF EXISTS import_jobs_kind_check;
ALTER TABLE public.import_jobs ADD CONSTRAINT import_jobs_kind_check
  CHECK (kind IN ('catalog','cogs','sales','inventory','fees','orders','ads','reviews','traffic','returns','search_terms','promotions','inventory_ledger'));

-- ------------------------------------------------------------
-- 10. derive_snapshots — canonical → sku_daily_snapshots (chỉ ASIN có trong danh mục)
--     NULL = không có dữ liệu; 0 = có dữ liệu và bằng 0 (orders: ngày có file nhưng ASIN không bán)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.derive_snapshots(p_tenant UUID, p_from DATE, p_to DATE, p_feeds TEXT[] DEFAULT ARRAY['orders','traffic','ads','inventory'])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n_orders INT := 0; n_traffic INT := 0; n_ads INT := 0; n_inv INT := 0; v_days INT;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền (data.import)'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RETURN jsonb_build_object('ok', false, 'error', 'khoảng ngày không hợp lệ'); END IF;

  IF 'orders' = ANY(p_feeds) THEN
    -- những ngày có ít nhất 1 order line trong tenant → ASIN danh mục không có đơn = 0
    WITH days AS (
      SELECT DISTINCT order_date AS d FROM public.orders WHERE tenant_id = p_tenant AND order_date BETWEEN p_from AND p_to
    ), agg AS (
      SELECT o.asin, o.order_date AS d, SUM(o.quantity) AS u, SUM(COALESCE(o.item_sales,0)) AS r
      FROM public.orders o WHERE o.tenant_id = p_tenant AND o.order_date BETWEEN p_from AND p_to AND NOT o.is_cancelled
      GROUP BY o.asin, o.order_date
    ), rows_ AS (
      SELECT k.id AS sku_id, days.d, k.tenant_id, k.asin, COALESCE(agg.u,0)::int AS units, COALESCE(agg.r,0)::numeric(14,2) AS revenue
      FROM public.amazon_skus k CROSS JOIN days LEFT JOIN agg ON agg.asin = k.asin AND agg.d = days.d
      WHERE k.tenant_id = p_tenant AND k.status = 'active'
    ), up AS (
      INSERT INTO public.sku_daily_snapshots AS s (sku_id, date, tenant_id, asin, units, revenue, sources)
      SELECT sku_id, d, tenant_id, asin, units, revenue, '{"orders":"canonical"}'::jsonb FROM rows_
      ON CONFLICT (sku_id, date) DO UPDATE SET units = EXCLUDED.units, revenue = EXCLUDED.revenue, sources = s.sources || EXCLUDED.sources
      RETURNING 1
    ) SELECT count(*) INTO n_orders FROM up;
  END IF;

  IF 'traffic' = ANY(p_feeds) THEN
    WITH up AS (
      INSERT INTO public.sku_daily_snapshots AS s (sku_id, date, tenant_id, asin, sessions, page_views, units, revenue, sources)
      SELECT k.id, t.date, k.tenant_id, k.asin, t.sessions, t.page_views, t.units_ordered, t.ordered_product_sales, '{"traffic":"canonical"}'::jsonb
      FROM public.traffic_daily t JOIN public.amazon_skus k ON k.tenant_id = t.tenant_id AND k.asin = t.asin
      WHERE t.tenant_id = p_tenant AND t.date BETWEEN p_from AND p_to
      ON CONFLICT (sku_id, date) DO UPDATE SET sessions = EXCLUDED.sessions, page_views = EXCLUDED.page_views,
        -- không ghi đè units/revenue đã có từ orders
        units = COALESCE(s.units, EXCLUDED.units), revenue = COALESCE(s.revenue, EXCLUDED.revenue), sources = s.sources || EXCLUDED.sources
      RETURNING 1
    ) SELECT count(*) INTO n_traffic FROM up;
  END IF;

  IF 'ads' = ANY(p_feeds) THEN
    WITH agg AS (
      SELECT a.asin, a.date, SUM(COALESCE(a.spend,0)) sp, SUM(COALESCE(a.sales,0)) sa, SUM(COALESCE(a.clicks,0)) cl, SUM(COALESCE(a.impressions,0)) im
      FROM public.ad_daily a WHERE a.tenant_id = p_tenant AND a.level = 'asin' AND a.date BETWEEN p_from AND p_to GROUP BY a.asin, a.date
    ), up AS (
      INSERT INTO public.sku_daily_snapshots AS s (sku_id, date, tenant_id, asin, ad_spend, ad_sales, ad_clicks, ad_impressions, sources)
      SELECT k.id, agg.date, k.tenant_id, k.asin, agg.sp, agg.sa, agg.cl, agg.im, '{"ads":"canonical"}'::jsonb
      FROM agg JOIN public.amazon_skus k ON k.tenant_id = p_tenant AND k.asin = agg.asin
      ON CONFLICT (sku_id, date) DO UPDATE SET ad_spend = EXCLUDED.ad_spend, ad_sales = EXCLUDED.ad_sales, ad_clicks = EXCLUDED.ad_clicks, ad_impressions = EXCLUDED.ad_impressions, sources = s.sources || EXCLUDED.sources
      RETURNING 1
    ) SELECT count(*) INTO n_ads FROM up;
  END IF;

  IF 'inventory' = ANY(p_feeds) THEN
    -- tổng theo ASIN × ngày (mọi SKU/FC) → snapshot + amazon_skus (ngày mới nhất)
    WITH agg AS (
      SELECT asin, date, SUM(COALESCE(available,0)) av, SUM(COALESCE(inbound,0)) ib
      FROM public.inventory_ledger WHERE tenant_id = p_tenant AND date BETWEEN p_from AND p_to GROUP BY asin, date
    ), up AS (
      INSERT INTO public.sku_daily_snapshots AS s (sku_id, date, tenant_id, asin, inventory_qty, inventory_inbound, sources)
      SELECT k.id, agg.date, k.tenant_id, k.asin, agg.av, agg.ib, '{"inventory":"canonical"}'::jsonb
      FROM agg JOIN public.amazon_skus k ON k.tenant_id = p_tenant AND k.asin = agg.asin
      ON CONFLICT (sku_id, date) DO UPDATE SET inventory_qty = EXCLUDED.inventory_qty, inventory_inbound = EXCLUDED.inventory_inbound, sources = s.sources || EXCLUDED.sources
      RETURNING 1
    ) SELECT count(*) INTO n_inv FROM up;
    UPDATE public.amazon_skus k SET inventory_qty = l.av, inventory_inbound = l.ib, last_ingested_at = now()
    FROM (SELECT DISTINCT ON (g.asin) g.asin, g.date, g.av, g.ib
          FROM (SELECT asin, date, SUM(COALESCE(available,0)) av, SUM(COALESCE(inbound,0)) ib
                FROM public.inventory_ledger WHERE tenant_id = p_tenant GROUP BY asin, date) g
          ORDER BY g.asin, g.date DESC) l
    WHERE k.tenant_id = p_tenant AND k.asin = l.asin AND l.date >= p_from;
  END IF;

  -- rolling 30 ngày về amazon_skus (không đòi has_role: đã kiểm quyền ở trên)
  WITH agg AS (
    SELECT sku_id, SUM(units) u, SUM(revenue) r, SUM(sessions) s, COUNT(*) FILTER (WHERE units IS NOT NULL) cov
    FROM public.sku_daily_snapshots WHERE tenant_id = p_tenant AND date > CURRENT_DATE - 30 AND date <= CURRENT_DATE GROUP BY sku_id
  )
  UPDATE public.amazon_skus k SET sales_last_30d = COALESCE(agg.u, k.sales_last_30d), revenue_last_30d = COALESCE(agg.r, k.revenue_last_30d),
    sessions_last_30d = COALESCE(agg.s, k.sessions_last_30d), last_ingested_at = now()
  FROM agg WHERE agg.sku_id = k.id AND agg.cov >= 20;
  GET DIAGNOSTICS v_days = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'orders_rows', n_orders, 'traffic_rows', n_traffic, 'ads_rows', n_ads, 'inventory_rows', n_inv, 'skus_rolling_updated', v_days);
END; $$;
GRANT EXECUTE ON FUNCTION public.derive_snapshots(UUID, DATE, DATE, TEXT[]) TO authenticated;

-- ------------------------------------------------------------
-- 11. v_data_freshness: ngày dữ liệu thật cho feed mới (cùng danh sách cột → CREATE OR REPLACE hợp lệ)
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
      WHEN 'orders_daily'        THEN GREATEST((SELECT MAX(order_date) FROM public.orders o WHERE o.tenant_id = tf.tenant_id), (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.units IS NOT NULL))
      WHEN 'sales_traffic_daily' THEN GREATEST((SELECT MAX(date) FROM public.traffic_daily x WHERE x.tenant_id = tf.tenant_id), (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.sessions IS NOT NULL))
      WHEN 'ads_daily'           THEN GREATEST((SELECT MAX(date) FROM public.ad_daily x WHERE x.tenant_id = tf.tenant_id), (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.ad_spend IS NOT NULL))
      WHEN 'inventory'           THEN (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tf.tenant_id AND s.inventory_qty IS NOT NULL)
      WHEN 'inventory_ledger'    THEN (SELECT MAX(date) FROM public.inventory_ledger x WHERE x.tenant_id = tf.tenant_id)
      WHEN 'returns'             THEN (SELECT MAX(return_date) FROM public.returns x WHERE x.tenant_id = tf.tenant_id)
      WHEN 'search_terms'        THEN (SELECT MAX(date) FROM public.search_terms x WHERE x.tenant_id = tf.tenant_id)
      WHEN 'promotions'          THEN (SELECT MAX(ingested_at)::date FROM public.promotions x WHERE x.tenant_id = tf.tenant_id)
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

-- Self-check
DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.tables WHERE table_schema = 'public'
    AND table_name IN ('orders','returns','ad_campaigns','ad_groups','ad_keywords','ad_daily','search_terms','promotions','traffic_daily','inventory_ledger');
  RAISE NOTICE '020 self-check: canonical tables=% (kỳ vọng 10), feeds=% (kỳ vọng 13)', n, (SELECT count(*) FROM public.data_feeds);
END $$;
