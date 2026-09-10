-- ============================================================
-- 006 — Daily snapshots + metric layer + đối soát  (Tuần 3‑4)
-- Chạy SAU 005. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. sku_daily_snapshots — bảng sự thật theo ngày (grain: sku × ngày)
--    NULL = chưa có dữ liệu ; 0 = có dữ liệu và bằng 0
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sku_daily_snapshots (
  sku_id               UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  date                 DATE NOT NULL,
  tenant_id            UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  asin                 TEXT NOT NULL,
  -- state (chụp hằng ngày)
  price                NUMERIC(12,2),
  cogs                 NUMERIC(12,2),
  fee_per_unit         NUMERIC(12,2),
  referral_fee_pct     NUMERIC(5,2),
  contribution_profit  NUMERIC(12,2),
  inventory_qty        INTEGER,
  inventory_inbound    INTEGER,
  reorder_point        INTEGER,
  -- flow (import theo ngày)
  units                INTEGER,
  revenue              NUMERIC(14,2),
  sessions             INTEGER,
  page_views           INTEGER,
  ad_spend             NUMERIC(12,2),
  ad_sales             NUMERIC(12,2),
  ad_clicks            INTEGER,
  ad_impressions       INTEGER,
  -- meta
  sources              JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (sku_id, date)
);
CREATE INDEX IF NOT EXISTS idx_snap_tenant_date ON public.sku_daily_snapshots(tenant_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_snap_asin_date   ON public.sku_daily_snapshots(tenant_id, asin, date DESC);

DROP TRIGGER IF EXISTS trg_snap_updated_at ON public.sku_daily_snapshots;
CREATE TRIGGER trg_snap_updated_at BEFORE UPDATE ON public.sku_daily_snapshots
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ------------------------------------------------------------
-- 2. Chụp trạng thái hằng ngày
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.capture_daily_snapshots(t UUID DEFAULT NULL, d DATE DEFAULT CURRENT_DATE, src TEXT DEFAULT 'cron')
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INTEGER;
BEGIN
  -- gọi từ client: phải là operator/owner của tenant
  IF auth.uid() IS NOT NULL AND (t IS NULL OR NOT public.has_role(t, ARRAY['owner','operator'])) THEN
    RAISE EXCEPTION 'Không đủ quyền chụp snapshot';
  END IF;

  INSERT INTO public.sku_daily_snapshots AS s
    (sku_id, date, tenant_id, asin, price, cogs, fee_per_unit, referral_fee_pct, contribution_profit,
     inventory_qty, reorder_point, sources)
  SELECT k.id, d, k.tenant_id, k.asin, k.current_price, k.cogs, k.fee_per_unit, k.referral_fee_pct, k.contribution_profit,
         k.inventory_qty, k.reorder_point, jsonb_build_object('state', src)
  FROM public.amazon_skus k
  WHERE k.status = 'active' AND (t IS NULL OR k.tenant_id = t)
  ON CONFLICT (sku_id, date) DO UPDATE SET
    price = EXCLUDED.price, cogs = EXCLUDED.cogs, fee_per_unit = EXCLUDED.fee_per_unit,
    referral_fee_pct = EXCLUDED.referral_fee_pct, contribution_profit = EXCLUDED.contribution_profit,
    inventory_qty = EXCLUDED.inventory_qty, reorder_point = EXCLUDED.reorder_point,
    sources = s.sources || EXCLUDED.sources;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.capture_daily_snapshots(UUID, DATE, TEXT) TO authenticated;

-- Lịch chạy 03:00 UTC hằng ngày (cần extension pg_cron: Database → Extensions → pg_cron)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'vexim_daily_snapshots';
    PERFORM cron.schedule('vexim_daily_snapshots', '0 3 * * *', $c$ SELECT public.capture_daily_snapshots(NULL, CURRENT_DATE, 'cron'); $c$);
  ELSE
    RAISE NOTICE 'pg_cron chưa có – dùng nút "Chụp snapshot" trên UI hoặc bật extension rồi chạy lại file này.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Không lên lịch được pg_cron: % – dùng nút chụp tay.', SQLERRM;
END $$;

-- Chụp ngay hôm nay để có điểm dữ liệu đầu tiên
SELECT public.capture_daily_snapshots(NULL, CURRENT_DATE, 'manual');

-- ------------------------------------------------------------
-- 3. Đồng bộ rolling 30 ngày từ snapshot về amazon_skus
--    (chỉ khi có >= 20/30 ngày dữ liệu để không ghi đè bằng số thiếu)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_sku_rolling_from_snapshots(t UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INTEGER;
BEGIN
  IF NOT public.has_role(t, ARRAY['owner','operator']) THEN
    RAISE EXCEPTION 'Không đủ quyền';
  END IF;
  WITH agg AS (
    SELECT sku_id, SUM(units) AS u, SUM(revenue) AS r, SUM(sessions) AS s,
           COUNT(*) FILTER (WHERE units IS NOT NULL) AS cov
    FROM public.sku_daily_snapshots
    WHERE tenant_id = t AND date > CURRENT_DATE - 30 AND date <= CURRENT_DATE
    GROUP BY sku_id
  )
  UPDATE public.amazon_skus k SET
    sales_last_30d    = COALESCE(agg.u, k.sales_last_30d),
    revenue_last_30d  = COALESCE(agg.r, k.revenue_last_30d),
    sessions_last_30d = COALESCE(agg.s, k.sessions_last_30d),
    last_ingested_at  = now()
  FROM agg WHERE agg.sku_id = k.id AND agg.cov >= 20;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.refresh_sku_rolling_from_snapshots(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 4. Metric layer — sku_metrics(t, asof, only_sku)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.sku_metrics(UUID, DATE, UUID);
CREATE FUNCTION public.sku_metrics(t UUID, asof DATE DEFAULT CURRENT_DATE, only_sku UUID DEFAULT NULL)
RETURNS TABLE (
  sku_id UUID, asin TEXT,
  velocity_7d NUMERIC, velocity_30d NUMERIC, velocity_change_pct NUMERIC, coverage_days_30 INTEGER,
  units_30d INTEGER, revenue_30d NUMERIC, cp_30d NUMERIC,
  price_avg_30 NUMERIC, price_volatility_pct NUMERIC,
  cp_unit_now NUMERIC, cp_margin_now_pct NUMERIC, cp_margin_baseline_pct NUMERIC, margin_delta_pts NUMERIC,
  days_of_cover NUMERIC, stockout_eta DATE, inventory_health TEXT,
  tacos_30 NUMERIC, acos_30 NUMERIC, cvr_30 NUMERIC, ad_spend_30 NUMERIC,
  last_sale_date DATE, days_since_last_sale INTEGER,
  snapshots_total INTEGER, first_snapshot DATE, last_snapshot DATE
) LANGUAGE sql STABLE AS $$
WITH pol AS (
  SELECT default_lead_time_days, safety_stock_days FROM public.policy_register WHERE tenant_id = t
),
base AS (  -- baseline margin từ kpi_baseline.snapshot nếu có
  SELECT e->>'asin' AS asin,
         CASE WHEN (e->>'price')::numeric > 0 THEN 100 * (e->>'cp')::numeric / (e->>'price')::numeric END AS m
  FROM public.kpi_baseline b, jsonb_array_elements(b.snapshot) e
  WHERE b.tenant_id = t AND b.is_active AND b.label = 'baseline'
),
w AS (
  SELECT s.sku_id,
    SUM(units)   FILTER (WHERE date > asof - 7)  AS u7,
    COUNT(units) FILTER (WHERE date > asof - 7)  AS c7,
    SUM(units)   FILTER (WHERE date > asof - 30) AS u30,
    COUNT(units) FILTER (WHERE date > asof - 30) AS c30,
    SUM(revenue) FILTER (WHERE date > asof - 30) AS r30,
    SUM(units * contribution_profit) FILTER (WHERE date > asof - 30) AS cp30,
    SUM(sessions) FILTER (WHERE date > asof - 30) AS sess30,
    SUM(ad_spend) FILTER (WHERE date > asof - 30) AS ads30,
    SUM(ad_sales) FILTER (WHERE date > asof - 30) AS adsales30,
    AVG(COALESCE(price, CASE WHEN units > 0 THEN revenue / units END)) FILTER (WHERE date > asof - 30) AS pavg,
    STDDEV_POP(COALESCE(price, CASE WHEN units > 0 THEN revenue / units END)) FILTER (WHERE date > asof - 30) AS psd,
    MAX(date) FILTER (WHERE units > 0) AS last_sale,
    COUNT(*) AS n_all, MIN(date) AS d_min, MAX(date) AS d_max
  FROM public.sku_daily_snapshots s
  WHERE s.tenant_id = t AND s.date <= asof AND (only_sku IS NULL OR s.sku_id = only_sku)
  GROUP BY s.sku_id
)
SELECT
  k.id, k.asin,
  CASE WHEN w.c7  > 0 THEN ROUND(w.u7::numeric  / w.c7, 2) END,
  CASE WHEN w.c30 > 0 THEN ROUND(w.u30::numeric / w.c30, 2) END,
  CASE WHEN w.c7 > 0 AND w.c30 > 0 AND w.u30 > 0
       THEN ROUND(100 * ((w.u7::numeric / w.c7) - (w.u30::numeric / w.c30)) / (w.u30::numeric / w.c30), 1) END,
  COALESCE(w.c30, 0)::int,
  w.u30::int, w.r30, w.cp30,
  ROUND(w.pavg, 2),
  CASE WHEN w.pavg > 0 THEN ROUND(100 * w.psd / w.pavg, 2) END,
  k.contribution_profit,
  CASE WHEN k.current_price > 0 THEN ROUND(100 * k.contribution_profit / k.current_price, 2) END,
  ROUND(base.m, 2),
  CASE WHEN base.m IS NOT NULL AND k.current_price > 0
       THEN ROUND(100 * k.contribution_profit / k.current_price - base.m, 2) END,
  -- days of cover: ưu tiên v7, rồi v30, rồi sales_last_30d/30
  CASE
    WHEN w.c7 > 0 AND w.u7 > 0  THEN ROUND(k.inventory_qty / (w.u7::numeric / w.c7), 1)
    WHEN w.c30 > 0 AND w.u30 > 0 THEN ROUND(k.inventory_qty / (w.u30::numeric / w.c30), 1)
    WHEN k.sales_last_30d > 0     THEN ROUND(k.inventory_qty / (k.sales_last_30d / 30.0), 1)
  END,
  CASE
    WHEN w.c7 > 0 AND w.u7 > 0  THEN asof + FLOOR(k.inventory_qty / (w.u7::numeric / w.c7))::int
    WHEN w.c30 > 0 AND w.u30 > 0 THEN asof + FLOOR(k.inventory_qty / (w.u30::numeric / w.c30))::int
    WHEN k.sales_last_30d > 0     THEN asof + FLOOR(k.inventory_qty / (k.sales_last_30d / 30.0))::int
  END,
  -- inventory health vs (lead time + safety stock)
  (SELECT CASE
     WHEN doc IS NULL THEN 'unknown'
     WHEN doc < need THEN 'critical'
     WHEN doc < need * 1.5 THEN 'warning'
     WHEN doc > need * 6 THEN 'overstock'
     ELSE 'healthy' END
   FROM (SELECT
      CASE
        WHEN w.c7 > 0 AND w.u7 > 0  THEN k.inventory_qty / (w.u7::numeric / w.c7)
        WHEN w.c30 > 0 AND w.u30 > 0 THEN k.inventory_qty / (w.u30::numeric / w.c30)
        WHEN k.sales_last_30d > 0     THEN k.inventory_qty / (k.sales_last_30d / 30.0)
      END AS doc,
      (COALESCE(k.lead_time_days, pol.default_lead_time_days, 30) + COALESCE(pol.safety_stock_days, 14))::numeric AS need
     FROM pol) x),
  CASE WHEN w.r30 > 0 THEN ROUND(100 * w.ads30 / w.r30, 2) END,
  CASE WHEN w.adsales30 > 0 THEN ROUND(100 * w.ads30 / w.adsales30, 2) END,
  CASE WHEN w.sess30 > 0 THEN ROUND(100 * w.u30::numeric / w.sess30, 2) END,
  w.ads30,
  w.last_sale,
  CASE WHEN w.last_sale IS NOT NULL THEN (asof - w.last_sale) END,
  COALESCE(w.n_all, 0)::int, w.d_min, w.d_max
FROM public.amazon_skus k
LEFT JOIN w ON w.sku_id = k.id
LEFT JOIN base ON base.asin = k.asin
LEFT JOIN pol ON TRUE
WHERE k.tenant_id = t AND (only_sku IS NULL OR k.id = only_sku);
$$;
GRANT EXECUTE ON FUNCTION public.sku_metrics(UUID, DATE, UUID) TO authenticated;

-- Chuỗi theo ngày cấp brand
DROP FUNCTION IF EXISTS public.tenant_daily(UUID, INTEGER);
CREATE FUNCTION public.tenant_daily(t UUID, days INTEGER DEFAULT 30)
RETURNS TABLE (date DATE, units BIGINT, revenue NUMERIC, cp NUMERIC, ad_spend NUMERIC, inventory_units BIGINT, skus_with_sales INTEGER)
LANGUAGE sql STABLE AS $$
  SELECT d::date,
         SUM(s.units), SUM(s.revenue), SUM(s.units * s.contribution_profit), SUM(s.ad_spend), SUM(s.inventory_qty),
         COUNT(*) FILTER (WHERE s.units IS NOT NULL)::int
  FROM generate_series(CURRENT_DATE - (days - 1), CURRENT_DATE, interval '1 day') d
  LEFT JOIN public.sku_daily_snapshots s ON s.date = d::date AND s.tenant_id = t
  GROUP BY d ORDER BY d;
$$;
GRANT EXECUTE ON FUNCTION public.tenant_daily(UUID, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 5. Đối soát với Seller Central
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_checks (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  period_start     DATE NOT NULL,
  period_end       DATE NOT NULL,
  sc_revenue       NUMERIC(14,2) NOT NULL,
  sc_units         INTEGER NOT NULL,
  sys_revenue      NUMERIC(14,2) NOT NULL,
  sys_units        INTEGER NOT NULL,
  revenue_diff_pct NUMERIC(8,2),
  units_diff_pct   NUMERIC(8,2),
  tolerance_pct    NUMERIC(5,2) NOT NULL,
  passed           BOOLEAN NOT NULL,
  note             TEXT,
  created_by       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_recon_tenant ON public.reconciliation_checks(tenant_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.run_reconciliation(t UUID, p_start DATE, p_end DATE, p_sc_revenue NUMERIC, p_sc_units INTEGER, p_note TEXT DEFAULT NULL)
RETURNS public.reconciliation_checks LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sys_r NUMERIC; sys_u INTEGER; tol NUMERIC; rdiff NUMERIC; udiff NUMERIC; rec public.reconciliation_checks;
BEGIN
  IF NOT public.has_role(t, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
  SELECT COALESCE(SUM(revenue),0), COALESCE(SUM(units),0) INTO sys_r, sys_u
    FROM public.sku_daily_snapshots WHERE tenant_id = t AND date BETWEEN p_start AND p_end;
  SELECT revenue_tolerance_pct INTO tol FROM public.policy_register WHERE tenant_id = t;
  tol := COALESCE(tol, 2);
  rdiff := CASE WHEN p_sc_revenue > 0 THEN ROUND(100 * (sys_r - p_sc_revenue) / p_sc_revenue, 2) END;
  udiff := CASE WHEN p_sc_units > 0 THEN ROUND(100 * (sys_u - p_sc_units)::numeric / p_sc_units, 2) END;
  INSERT INTO public.reconciliation_checks
    (tenant_id, period_start, period_end, sc_revenue, sc_units, sys_revenue, sys_units, revenue_diff_pct, units_diff_pct, tolerance_pct, passed, note, created_by)
  VALUES (t, p_start, p_end, p_sc_revenue, p_sc_units, sys_r, sys_u, rdiff, udiff, tol,
          COALESCE(abs(rdiff) <= tol, FALSE) AND COALESCE(abs(udiff) <= tol, FALSE), p_note, auth.uid())
  RETURNING * INTO rec;
  RETURN rec;
END; $$;
GRANT EXECUTE ON FUNCTION public.run_reconciliation(UUID, DATE, DATE, NUMERIC, INTEGER, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 6. View trạng thái kết nối dữ liệu + gate tuần 3‑4
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_data_connections WITH (security_invoker = true) AS
SELECT
  tn.id AS tenant_id,
  (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tn.id AND s.price IS NOT NULL) AS last_state_snapshot,
  (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tn.id AND s.units IS NOT NULL) AS last_sales_date,
  (SELECT MAX(date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tn.id AND s.ad_spend IS NOT NULL) AS last_ads_date,
  (SELECT COUNT(DISTINCT date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tn.id AND s.units IS NOT NULL AND s.date > CURRENT_DATE - 30) AS sales_days_30,
  (SELECT COUNT(DISTINCT date) FROM public.sku_daily_snapshots s WHERE s.tenant_id = tn.id AND s.ad_spend IS NOT NULL AND s.date > CURRENT_DATE - 30) AS ads_days_30,
  (SELECT MAX(created_at) FROM public.import_jobs j WHERE j.tenant_id = tn.id AND j.kind = 'orders') AS last_orders_import,
  (SELECT MAX(created_at) FROM public.import_jobs j WHERE j.tenant_id = tn.id AND j.kind = 'ads') AS last_ads_import,
  (SELECT MAX(created_at) FROM public.import_jobs j WHERE j.tenant_id = tn.id AND j.kind IN ('catalog','cogs','fees','inventory','sales')) AS last_other_import,
  (SELECT passed FROM public.reconciliation_checks r WHERE r.tenant_id = tn.id ORDER BY created_at DESC LIMIT 1) AS last_recon_passed,
  (SELECT created_at FROM public.reconciliation_checks r WHERE r.tenant_id = tn.id ORDER BY created_at DESC LIMIT 1) AS last_recon_at,
  -- % doanh thu 30 ngày (theo amazon_skus) thuộc SKU có >= 20 ngày dữ liệu bán
  (SELECT CASE WHEN SUM(rev) > 0 THEN ROUND(100 * SUM(rev) FILTER (WHERE cov >= 20) / SUM(rev), 1) ELSE 0 END
     FROM (SELECT k.id, COALESCE(k.revenue_last_30d, k.current_price * k.sales_last_30d) AS rev,
                  (SELECT COUNT(*) FROM public.sku_daily_snapshots s WHERE s.sku_id = k.id AND s.units IS NOT NULL AND s.date > CURRENT_DATE - 30) AS cov
           FROM public.amazon_skus k WHERE k.tenant_id = tn.id AND k.status = 'active') x) AS coverage_revenue_pct
FROM public.tenants tn;
GRANT SELECT ON public.v_data_connections TO authenticated;

-- ------------------------------------------------------------
-- 7. import_jobs: thêm loại orders / ads
-- ------------------------------------------------------------
ALTER TABLE public.import_jobs DROP CONSTRAINT IF EXISTS import_jobs_kind_check;
ALTER TABLE public.import_jobs ADD CONSTRAINT import_jobs_kind_check
  CHECK (kind IN ('catalog','cogs','sales','inventory','fees','orders','ads'));

-- ------------------------------------------------------------
-- 8. RLS
-- ------------------------------------------------------------
ALTER TABLE public.sku_daily_snapshots   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_checks ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies
           WHERE schemaname='public' AND tablename IN ('sku_daily_snapshots','reconciliation_checks')
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP;
END $$;
CREATE POLICY snap_select ON public.sku_daily_snapshots FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY snap_write ON public.sku_daily_snapshots FOR ALL TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner','operator']))
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY recon_select ON public.reconciliation_checks FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));

-- Kiểm tra nhanh
SELECT * FROM public.v_data_connections;
