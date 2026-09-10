-- ============================================================
-- 024 — PHASE 3: Daily Operations Cockpit
-- Chạy SAU 023. Idempotent. Chỉ ĐỌC dữ liệu canonical; không tạo hành động lên Amazon.
--   • ops_cockpit(t, asof): 9 nhóm (orders, inventory, returns, keywords, traffic, conversion, promotions, reviews, advertising)
--     mỗi nhóm: freshness/DQ badge, KPI 1/7/30 ngày + baseline (30 ngày trước đó), danh sách chi tiết. Missing ≠ zero: KPI NULL khi không có dữ liệu.
--   • cockpit_actions(t): hàng đợi P0–P3 từ luật xác định, mỗi mục có evidence/owner/deadline/link.
--   • cockpit_open_task(t, action): chuyển 1 mục thành task (bảng tasks) có evidence — không tự động, người bấm.
--   • policy_register: ngưỡng cockpit (cấu hình được).
-- ============================================================

ALTER TABLE public.policy_register
  ADD COLUMN IF NOT EXISTS cockpit_thresholds JSONB NOT NULL DEFAULT '{
    "orders_drop_pct": 30, "orders_zero_days": 2, "doc_critical_days": 14, "doc_warning_days": 28,
    "return_rate_pct": 8, "return_rate_baseline_x": 1.5, "cvr_drop_pct": 25, "sessions_drop_pct": 30,
    "acos_max_pct": 35, "ads_spend_no_sales_usd": 20, "search_term_min_clicks": 15, "review_max_rating": 3,
    "buy_box_min_pct": 90, "unfulfillable_min": 5, "aged_180_min": 20 }'::jsonb;

-- tasks: thêm nguồn cockpit + loại
ALTER TABLE public.tasks DROP CONSTRAINT IF EXISTS tasks_source_type_check;
ALTER TABLE public.tasks ADD CONSTRAINT tasks_source_type_check CHECK (source_type IN ('voc_ticket','listing_audit','exception','recommendation','manual','cockpit'));
ALTER TABLE public.tasks DROP CONSTRAINT IF EXISTS tasks_type_check;
ALTER TABLE public.tasks ADD CONSTRAINT tasks_type_check CHECK (type IN ('content','qa_product','ads_guardrail','support','inventory_investigation','content_opportunity','keyword_opportunity','promo_review','conversion_diagnosis','other'));
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS dedupe_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_tasks_open_dedupe ON public.tasks(tenant_id, dedupe_key) WHERE dedupe_key IS NOT NULL AND status IN ('open','in_progress','blocked');

-- ------------------------------------------------------------
-- 1. Freshness helper cho 1 feed (badge)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.feed_badge(t UUID, p_feed TEXT)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH f AS (SELECT * FROM public.data_feeds WHERE feed_key = p_feed),
  lo AS (SELECT MAX(finished_at) AS at, (array_agg(status ORDER BY finished_at DESC))[1] AS st
         FROM public.ingestion_runs WHERE tenant_id = t AND feed_key = p_feed AND status IN ('succeeded','partial','failed')),
  dd AS (SELECT CASE p_feed
           WHEN 'orders_daily' THEN (SELECT MAX(order_date) FROM public.orders WHERE tenant_id = t)
           WHEN 'sales_traffic_daily' THEN (SELECT MAX(date) FROM public.traffic_daily WHERE tenant_id = t)
           WHEN 'ads_daily' THEN (SELECT MAX(date) FROM public.ad_daily WHERE tenant_id = t)
           WHEN 'search_terms' THEN (SELECT MAX(date) FROM public.search_terms WHERE tenant_id = t)
           WHEN 'returns' THEN (SELECT MAX(return_date) FROM public.returns WHERE tenant_id = t)
           WHEN 'inventory_ledger' THEN (SELECT MAX(date) FROM public.inventory_ledger WHERE tenant_id = t)
           WHEN 'inventory' THEN (SELECT MAX(date) FROM public.sku_daily_snapshots WHERE tenant_id = t AND inventory_qty IS NOT NULL)
           WHEN 'promotions' THEN (SELECT MAX(ingested_at)::date FROM public.promotions WHERE tenant_id = t)
           WHEN 'reviews' THEN (SELECT MAX(COALESCE(reviewed_at::date, created_at::date)) FROM public.raw_reviews WHERE tenant_id = t)
         END AS d)
  SELECT jsonb_build_object(
    'feed', p_feed, 'label', (SELECT label FROM f), 'last_data_date', (SELECT d FROM dd), 'last_run_at', (SELECT at FROM lo), 'last_run_status', (SELECT st FROM lo),
    'sla_hours', (SELECT sla_hours FROM f), 'settlement_lag_days', (SELECT settlement_lag_days FROM f),
    'status', CASE
      WHEN (SELECT d FROM dd) IS NULL AND (SELECT at FROM lo) IS NULL THEN 'missing'
      WHEN (SELECT at FROM lo) IS NOT NULL AND (SELECT at FROM lo) < now() - make_interval(hours => (SELECT sla_hours FROM f)) THEN 'stale'
      WHEN (SELECT at FROM lo) IS NULL AND (SELECT d FROM dd) < CURRENT_DATE - GREATEST(1, ((SELECT sla_hours FROM f) / 24)::int) - (SELECT settlement_lag_days FROM f) THEN 'stale'
      ELSE 'fresh' END);
$$;
GRANT EXECUTE ON FUNCTION public.feed_badge(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 2. ops_cockpit
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ops_cockpit(t UUID, asof DATE DEFAULT CURRENT_DATE - 1)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  th JSONB; res JSONB := '{}'::jsonb; g JSONB; d1 DATE := asof; d7 DATE := asof - 6; d30 DATE := asof - 29; b30s DATE := asof - 59; b30e DATE := asof - 30;
  has_orders BOOLEAN; inv_known BOOLEAN; has_traffic BOOLEAN; has_ads BOOLEAN; has_st BOOLEAN; has_ret BOOLEAN; has_inv BOOLEAN; has_promo BOOLEAN; has_rev BOOLEAN;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT (t IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không thuộc tenant'; END IF;
  SELECT cockpit_thresholds INTO th FROM public.policy_register WHERE tenant_id = t;
  th := COALESCE(th, '{}'::jsonb);
  has_orders := EXISTS (SELECT 1 FROM public.orders WHERE tenant_id = t);
  has_traffic := EXISTS (SELECT 1 FROM public.traffic_daily WHERE tenant_id = t);
  has_ads := EXISTS (SELECT 1 FROM public.ad_daily WHERE tenant_id = t);
  has_st := EXISTS (SELECT 1 FROM public.search_terms WHERE tenant_id = t);
  has_ret := EXISTS (SELECT 1 FROM public.returns WHERE tenant_id = t);
  -- tồn kho chỉ được coi là "đã biết" khi có ledger, snapshot tồn, hoặc run feed inventory thành công — nếu không, inventory_qty=0 mặc định KHÔNG được hiểu là hết hàng
  inv_known := EXISTS (SELECT 1 FROM public.inventory_ledger WHERE tenant_id = t)
            OR EXISTS (SELECT 1 FROM public.sku_daily_snapshots WHERE tenant_id = t AND inventory_qty IS NOT NULL AND sources ? 'inventory')
            OR EXISTS (SELECT 1 FROM public.ingestion_runs WHERE tenant_id = t AND feed_key IN ('inventory','inventory_ledger') AND status IN ('succeeded','partial'));
  has_inv := inv_known;
  has_promo := EXISTS (SELECT 1 FROM public.promotions WHERE tenant_id = t);
  has_rev := EXISTS (SELECT 1 FROM public.raw_reviews WHERE tenant_id = t);

  -- ---------- 1. ORDERS (canonical orders; fallback snapshots) ----------
  WITH src AS (
    SELECT order_date AS d, asin, SUM(quantity) u, SUM(COALESCE(item_sales,0)) r FROM public.orders WHERE tenant_id = t AND NOT is_cancelled AND order_date BETWEEN b30s AND d1 GROUP BY 1,2
    UNION ALL
    SELECT date, asin, units, revenue FROM public.sku_daily_snapshots s WHERE NOT has_orders AND s.tenant_id = t AND s.units IS NOT NULL AND date BETWEEN b30s AND d1
  ), days AS (SELECT DISTINCT d FROM src),
  k AS (
    SELECT (SELECT SUM(u) FROM src WHERE d = d1) u1, (SELECT SUM(r) FROM src WHERE d = d1) r1,
           (SELECT SUM(u) FROM src WHERE d BETWEEN d7 AND d1) u7, (SELECT SUM(r) FROM src WHERE d BETWEEN d7 AND d1) r7,
           (SELECT SUM(u) FROM src WHERE d BETWEEN d30 AND d1) u30, (SELECT SUM(r) FROM src WHERE d BETWEEN d30 AND d1) r30,
           (SELECT SUM(u) FROM src WHERE d BETWEEN b30s AND b30e) ub, (SELECT SUM(r) FROM src WHERE d BETWEEN b30s AND b30e) rb,
           (SELECT count(*) FROM days WHERE d BETWEEN d7 AND d1) cov7, (SELECT count(*) FROM days WHERE d BETWEEN d30 AND d1) cov30, (SELECT count(*) FROM days WHERE d BETWEEN b30s AND b30e) covb
  ), per_asin AS (
    SELECT s.asin, k2.title, SUM(s.u) FILTER (WHERE s.d BETWEEN d7 AND d1) u7, SUM(s.u) FILTER (WHERE s.d BETWEEN d30 AND d1) u30, SUM(s.u) FILTER (WHERE s.d BETWEEN b30s AND b30e) ub,
           MAX(s.d) FILTER (WHERE s.u > 0) last_sale
    FROM src s LEFT JOIN public.amazon_skus k2 ON k2.tenant_id = t AND k2.asin = s.asin GROUP BY s.asin, k2.title
  )
  SELECT jsonb_build_object(
    'badge', public.feed_badge(t, 'orders_daily'), 'has_data', has_orders OR EXISTS (SELECT 1 FROM src),
    'kpi', jsonb_build_object('units_1d', u1, 'revenue_1d', r1, 'units_7d', u7, 'revenue_7d', r7, 'units_30d', u30, 'revenue_30d', r30,
      'units_baseline_30d', ub, 'revenue_baseline_30d', rb, 'coverage_7d', cov7, 'coverage_30d', cov30, 'coverage_baseline', covb,
      'units_7d_daily', CASE WHEN cov7 > 0 THEN round(u7::numeric / cov7, 1) END,
      'units_30d_daily', CASE WHEN cov30 > 0 THEN round(u30::numeric / cov30, 1) END,
      'units_baseline_daily', CASE WHEN covb > 0 THEN round(ub::numeric / covb, 1) END,
      'change_7d_vs_baseline_pct', CASE WHEN cov7 > 0 AND covb > 0 AND ub > 0 THEN round(100 * ((u7::numeric / cov7) - (ub::numeric / covb)) / (ub::numeric / covb), 1) END),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('asin', asin, 'title', title, 'units_7d', u7, 'units_30d', u30, 'units_baseline', ub,
        'change_pct', CASE WHEN ub > 0 THEN round(100 * (COALESCE(u7,0) * 30.0 / 7 - ub) / ub, 1) END, 'last_sale', last_sale) ORDER BY COALESCE(u30,0) DESC) FROM (SELECT * FROM per_asin LIMIT 50) x), '[]'::jsonb))
  INTO g FROM k;
  res := res || jsonb_build_object('orders', g);

  -- ---------- 2. INVENTORY ----------
  WITH led AS (
    SELECT asin, SUM(COALESCE(available,0)) av, SUM(COALESCE(reserved,0)) rs, SUM(COALESCE(inbound,0)) ib, SUM(COALESCE(unfulfillable,0)) uf, SUM(COALESCE(aged_180,0)+COALESCE(aged_270,0)+COALESCE(aged_365,0)) aged, MAX(date) d
    FROM public.inventory_ledger WHERE tenant_id = t AND date = (SELECT MAX(date) FROM public.inventory_ledger WHERE tenant_id = t) GROUP BY asin
  ), m AS (SELECT * FROM public.sku_metrics(t, asof)),
  rows_ AS (
    SELECT k.asin, k.title, COALESCE(l.av, CASE WHEN inv_known THEN k.inventory_qty END) available, COALESCE(l.ib, CASE WHEN inv_known THEN k.inventory_inbound END) inbound, l.rs reserved, l.uf unfulfillable, l.aged aged_180_plus,
           m.velocity_7d, m.velocity_30d, m.days_of_cover, m.stockout_eta, m.inventory_health, l.d ledger_date
    FROM public.amazon_skus k LEFT JOIN led l ON l.asin = k.asin LEFT JOIN m ON m.sku_id = k.id WHERE k.tenant_id = t AND k.status = 'active'
  )
  SELECT jsonb_build_object(
    'badge', CASE WHEN EXISTS (SELECT 1 FROM public.inventory_ledger WHERE tenant_id = t) THEN public.feed_badge(t, 'inventory_ledger') ELSE public.feed_badge(t, 'inventory') END,
    'has_data', has_inv,
    'kpi', jsonb_build_object('skus', count(*), 'critical', count(*) FILTER (WHERE inventory_health = 'critical'), 'warning', count(*) FILTER (WHERE inventory_health = 'warning'),
      'overstock', count(*) FILTER (WHERE inventory_health = 'overstock'), 'unknown', count(*) FILTER (WHERE inventory_health = 'unknown' OR inventory_health IS NULL),
      'units_available', SUM(available), 'units_inbound', SUM(inbound), 'unfulfillable', SUM(unfulfillable), 'aged_180_plus', SUM(aged_180_plus)),
    'items', COALESCE(jsonb_agg(to_jsonb(rows_) ORDER BY CASE inventory_health WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 WHEN 'overstock' THEN 2 WHEN 'unknown' THEN 3 ELSE 4 END, days_of_cover NULLS LAST), '[]'::jsonb))
  INTO g FROM rows_;
  res := res || jsonb_build_object('inventory', g);

  -- ---------- 3. RETURNS ----------
  WITH r AS (SELECT * FROM public.returns WHERE tenant_id = t AND return_date BETWEEN b30s AND d1),
  o AS (SELECT asin, SUM(quantity) FILTER (WHERE order_date BETWEEN d30 AND d1) u30, SUM(quantity) FILTER (WHERE order_date BETWEEN b30s AND b30e) ub FROM public.orders WHERE tenant_id = t AND NOT is_cancelled AND order_date BETWEEN b30s AND d1 GROUP BY asin),
  k AS (
    SELECT (SELECT SUM(quantity) FROM r WHERE return_date BETWEEN d7 AND d1) q7, (SELECT SUM(quantity) FROM r WHERE return_date BETWEEN d30 AND d1) q30, (SELECT SUM(quantity) FROM r WHERE return_date BETWEEN b30s AND b30e) qb,
           (SELECT SUM(refund_amount) FROM r WHERE return_date BETWEEN d30 AND d1) refund30, (SELECT SUM(u30) FROM o) ou30, (SELECT SUM(ub) FROM o) oub
  ), per AS (
    SELECT r.asin, k2.title, SUM(r.quantity) q30, o.u30, CASE WHEN o.u30 > 0 THEN round(100.0 * SUM(r.quantity) / o.u30, 1) END rate_pct,
           (SELECT array_agg(x.reason || ' ×' || x.c ORDER BY x.c DESC) FROM (SELECT reason, count(*) c FROM r r2 WHERE r2.asin = r.asin AND r2.return_date BETWEEN d30 AND d1 AND reason IS NOT NULL GROUP BY reason ORDER BY c DESC LIMIT 3) x) top_reasons,
           (SELECT array_agg(left(customer_comment, 120)) FROM (SELECT customer_comment FROM r r3 WHERE r3.asin = r.asin AND r3.customer_comment IS NOT NULL AND r3.return_date BETWEEN d30 AND d1 ORDER BY return_date DESC LIMIT 3) y) comments
    FROM r LEFT JOIN o ON o.asin = r.asin LEFT JOIN public.amazon_skus k2 ON k2.tenant_id = t AND k2.asin = r.asin WHERE r.return_date BETWEEN d30 AND d1 GROUP BY r.asin, k2.title, o.u30
  )
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'returns'), 'has_data', has_ret,
    'kpi', jsonb_build_object('qty_7d', q7, 'qty_30d', q30, 'qty_baseline_30d', qb, 'refund_30d', refund30,
      'rate_30d_pct', CASE WHEN ou30 > 0 THEN round(100.0 * COALESCE(q30,0) / ou30, 2) END, 'rate_baseline_pct', CASE WHEN oub > 0 THEN round(100.0 * COALESCE(qb,0) / oub, 2) END),
    'items', COALESCE((SELECT jsonb_agg(to_jsonb(per) ORDER BY q30 DESC) FROM per), '[]'::jsonb))
  INTO g FROM k;
  res := res || jsonb_build_object('returns', g);

  -- ---------- 4. CONVERTING KEYWORDS (search terms) ----------
  WITH st AS (SELECT * FROM public.search_terms WHERE tenant_id = t AND date BETWEEN d30 AND d1),
  agg AS (
    SELECT search_term, SUM(COALESCE(impressions,0)) imp, SUM(COALESCE(clicks,0)) cl, SUM(COALESCE(spend,0)) sp, SUM(COALESCE(orders,0)) od, SUM(COALESCE(sales,0)) sa,
           array_agg(DISTINCT asin) FILTER (WHERE asin <> '') asins, array_agg(DISTINCT campaign_key) FILTER (WHERE campaign_key <> '') campaigns,
           bool_or(lower(match_type) = 'exact') has_exact
    FROM st GROUP BY search_term
  )
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'search_terms'), 'has_data', has_st,
    'kpi', jsonb_build_object('terms_30d', count(*), 'converting', count(*) FILTER (WHERE od > 0), 'wasted_spend_30d', SUM(sp) FILTER (WHERE od = 0 AND cl >= COALESCE((th->>'search_term_min_clicks')::int, 15)),
      'spend_30d', SUM(sp), 'sales_30d', SUM(sa)),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('search_term', search_term, 'impressions', imp, 'clicks', cl, 'spend', sp, 'orders', od, 'sales', sa,
        'cvr_pct', CASE WHEN cl > 0 THEN round(100.0 * od / cl, 1) END, 'acos_pct', CASE WHEN sa > 0 THEN round(100 * sp / sa, 1) END, 'asins', asins, 'campaigns', campaigns, 'has_exact', has_exact,
        'kind', CASE WHEN od >= 2 AND NOT has_exact THEN 'harvest' WHEN od = 0 AND cl >= COALESCE((th->>'search_term_min_clicks')::int, 15) THEN 'negative' WHEN od > 0 THEN 'converting' ELSE 'watch' END)
        ORDER BY od DESC, sp DESC) FROM (SELECT * FROM agg ORDER BY od DESC, sp DESC LIMIT 60) x), '[]'::jsonb))
  INTO g FROM agg;
  res := res || jsonb_build_object('keywords', g);

  -- ---------- 5. TRAFFIC ----------
  WITH tr AS (SELECT * FROM public.traffic_daily WHERE tenant_id = t AND date BETWEEN b30s AND d1),
  days AS (SELECT DISTINCT date d FROM tr),
  k AS (SELECT (SELECT SUM(sessions) FROM tr WHERE date = d1) s1, (SELECT SUM(sessions) FROM tr WHERE date BETWEEN d7 AND d1) s7, (SELECT SUM(sessions) FROM tr WHERE date BETWEEN d30 AND d1) s30, (SELECT SUM(sessions) FROM tr WHERE date BETWEEN b30s AND b30e) sb,
              (SELECT SUM(page_views) FROM tr WHERE date BETWEEN d7 AND d1) pv7, (SELECT SUM(impressions) FROM tr WHERE date BETWEEN d7 AND d1) imp7, (SELECT SUM(clicks) FROM tr WHERE date BETWEEN d7 AND d1) cl7,
              (SELECT count(*) FROM days WHERE d BETWEEN d7 AND d1) cov7, (SELECT count(*) FROM days WHERE d BETWEEN b30s AND b30e) covb),
  ads AS (SELECT asin, SUM(COALESCE(clicks,0)) acl FROM public.ad_daily WHERE tenant_id = t AND level = 'asin' AND date BETWEEN d7 AND d1 GROUP BY asin),
  per AS (
    SELECT tr.asin, k2.title, SUM(sessions) FILTER (WHERE date BETWEEN d7 AND d1) s7, SUM(sessions) FILTER (WHERE date BETWEEN b30s AND b30e) sb, AVG(buy_box_pct) FILTER (WHERE date BETWEEN d7 AND d1) bb7,
           ads.acl paid_clicks_7d
    FROM tr LEFT JOIN public.amazon_skus k2 ON k2.tenant_id = t AND k2.asin = tr.asin LEFT JOIN ads ON ads.asin = tr.asin GROUP BY tr.asin, k2.title, ads.acl
  )
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'sales_traffic_daily'), 'has_data', has_traffic,
    'kpi', jsonb_build_object('sessions_1d', s1, 'sessions_7d', s7, 'sessions_30d', s30, 'sessions_baseline_30d', sb, 'page_views_7d', pv7, 'impressions_7d', imp7, 'clicks_7d', cl7,
      'ctr_7d_pct', CASE WHEN imp7 > 0 THEN round(100.0 * cl7 / imp7, 2) END, 'coverage_7d', cov7,
      'sessions_7d_daily', CASE WHEN cov7 > 0 THEN round(s7::numeric / cov7, 1) END, 'sessions_baseline_daily', CASE WHEN covb > 0 THEN round(sb::numeric / covb, 1) END,
      'change_7d_vs_baseline_pct', CASE WHEN cov7 > 0 AND covb > 0 AND sb > 0 THEN round(100 * ((s7::numeric / cov7) - (sb::numeric / covb)) / (sb::numeric / covb), 1) END,
      'paid_share_7d_pct', CASE WHEN s7 > 0 AND (SELECT SUM(acl) FROM ads) IS NOT NULL THEN LEAST(100, round(100.0 * (SELECT SUM(acl) FROM ads) / s7, 1)) END),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('asin', asin, 'title', title, 'sessions_7d', s7, 'sessions_baseline', sb, 'buy_box_pct', round(bb7, 1), 'paid_clicks_7d', paid_clicks_7d,
        'paid_share_pct', CASE WHEN s7 > 0 AND paid_clicks_7d IS NOT NULL THEN LEAST(100, round(100.0 * paid_clicks_7d / s7, 1)) END,
        'change_pct', CASE WHEN sb > 0 THEN round(100 * (COALESCE(s7,0) * 30.0 / 7 - sb) / sb, 1) END) ORDER BY s7 DESC NULLS LAST) FROM per), '[]'::jsonb))
  INTO g FROM k;
  res := res || jsonb_build_object('traffic', g);

  -- ---------- 6. CONVERSION ----------
  WITH tr AS (SELECT * FROM public.traffic_daily WHERE tenant_id = t AND date BETWEEN b30s AND d1),
  k AS (SELECT (SELECT SUM(units_ordered) FROM tr WHERE date BETWEEN d7 AND d1) u7, (SELECT SUM(sessions) FROM tr WHERE date BETWEEN d7 AND d1) s7,
              (SELECT SUM(units_ordered) FROM tr WHERE date BETWEEN d30 AND d1) u30, (SELECT SUM(sessions) FROM tr WHERE date BETWEEN d30 AND d1) s30,
              (SELECT SUM(units_ordered) FROM tr WHERE date BETWEEN b30s AND b30e) ub, (SELECT SUM(sessions) FROM tr WHERE date BETWEEN b30s AND b30e) sb),
  per AS (
    SELECT tr.asin, k2.title, k2.current_price, SUM(units_ordered) FILTER (WHERE date BETWEEN d7 AND d1) u7, SUM(sessions) FILTER (WHERE date BETWEEN d7 AND d1) s7,
           SUM(units_ordered) FILTER (WHERE date BETWEEN b30s AND b30e) ub, SUM(sessions) FILTER (WHERE date BETWEEN b30s AND b30e) sb, AVG(buy_box_pct) FILTER (WHERE date BETWEEN d7 AND d1) bb7,
           (SELECT round(AVG(rating),2) FROM public.raw_reviews rv WHERE rv.tenant_id = t AND rv.asin = tr.asin AND COALESCE(rv.reviewed_at::date, rv.created_at::date) BETWEEN d30 AND d1) rating_30d,
           (SELECT count(*) FROM public.promotions p WHERE p.tenant_id = t AND tr.asin = ANY(p.asins) AND p.start_at <= d1 AND COALESCE(p.end_at, d1) >= d7) promos_active
    FROM tr LEFT JOIN public.amazon_skus k2 ON k2.tenant_id = t AND k2.asin = tr.asin GROUP BY tr.asin, k2.title, k2.current_price
  )
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'sales_traffic_daily'), 'has_data', has_traffic,
    'kpi', jsonb_build_object('cvr_7d_pct', CASE WHEN s7 > 0 THEN round(100.0 * u7 / s7, 2) END, 'cvr_30d_pct', CASE WHEN s30 > 0 THEN round(100.0 * u30 / s30, 2) END,
      'cvr_baseline_pct', CASE WHEN sb > 0 THEN round(100.0 * ub / sb, 2) END,
      'change_7d_vs_baseline_pct', CASE WHEN s7 > 0 AND sb > 0 AND ub > 0 THEN round(100 * ((u7::numeric / s7) - (ub::numeric / sb)) / (ub::numeric / sb), 1) END),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('asin', asin, 'title', title, 'price', current_price, 'cvr_7d_pct', CASE WHEN s7 > 0 THEN round(100.0 * u7 / s7, 2) END,
        'cvr_baseline_pct', CASE WHEN sb > 0 THEN round(100.0 * ub / sb, 2) END, 'sessions_7d', s7, 'units_7d', u7, 'buy_box_pct', round(bb7, 1), 'rating_30d', rating_30d, 'promos_active', promos_active,
        'change_pct', CASE WHEN s7 > 0 AND sb > 0 AND ub > 0 THEN round(100 * ((u7::numeric / s7) - (ub::numeric / sb)) / (ub::numeric / sb), 1) END,
        'diagnosis', CASE WHEN s7 IS NULL OR s7 = 0 THEN 'no_traffic' WHEN bb7 IS NOT NULL AND bb7 < COALESCE((th->>'buy_box_min_pct')::numeric, 90) THEN 'buy_box'
                          WHEN rating_30d IS NOT NULL AND rating_30d < 3.8 THEN 'reviews' WHEN promos_active > 0 THEN 'promo_effect'
                          WHEN sb > 0 AND ub > 0 AND s7 > 0 AND ((u7::numeric / s7) - (ub::numeric / sb)) / (ub::numeric / sb) * 100 < -COALESCE((th->>'cvr_drop_pct')::numeric, 25) THEN 'content_or_price' ELSE 'ok' END)
        ORDER BY s7 DESC NULLS LAST) FROM per), '[]'::jsonb))
  INTO g FROM k;
  res := res || jsonb_build_object('conversion', g);

  -- ---------- 7. PROMOTIONS ----------
  WITH p AS (SELECT * FROM public.promotions WHERE tenant_id = t AND start_at <= d1 + 14 AND COALESCE(end_at, start_at) >= d30),
  per AS (
    SELECT p.id, p.promo_id, p.promo_type, p.name, p.asins, p.start_at, p.end_at, p.discount_type, p.discount_value, p.budget, p.status, p.margin_note,
           CASE WHEN p.start_at > d1 THEN 'upcoming' WHEN COALESCE(p.end_at, d1) >= d1 THEN 'active' ELSE 'ended' END phase,
           -- units trong kỳ vs 14 ngày trước kỳ (chỉ khi có dữ liệu)
           (SELECT SUM(quantity) FROM public.orders o WHERE o.tenant_id = t AND NOT o.is_cancelled AND o.asin = ANY(p.asins) AND o.order_date BETWEEN p.start_at AND LEAST(COALESCE(p.end_at, d1), d1)) units_in,
           (SELECT count(DISTINCT order_date) FROM public.orders o WHERE o.tenant_id = t AND o.asin = ANY(p.asins) AND o.order_date BETWEEN p.start_at AND LEAST(COALESCE(p.end_at, d1), d1)) days_in,
           (SELECT SUM(quantity) FROM public.orders o WHERE o.tenant_id = t AND NOT o.is_cancelled AND o.asin = ANY(p.asins) AND o.order_date BETWEEN p.start_at - 14 AND p.start_at - 1) units_pre,
           (SELECT count(DISTINCT order_date) FROM public.orders o WHERE o.tenant_id = t AND o.asin = ANY(p.asins) AND o.order_date BETWEEN p.start_at - 14 AND p.start_at - 1) days_pre,
           (SELECT MIN(CASE WHEN k2.current_price > 0 THEN 100 * (k2.current_price * (1 - CASE WHEN p.discount_type = 'percent' THEN COALESCE(p.discount_value,0)/100 ELSE 0 END) - CASE WHEN p.discount_type = 'amount' THEN COALESCE(p.discount_value,0) ELSE 0 END - k2.cogs - k2.fee_per_unit - k2.current_price * k2.referral_fee_pct / 100) / k2.current_price END)
              FROM public.amazon_skus k2 WHERE k2.tenant_id = t AND k2.asin = ANY(p.asins)) min_margin_after_pct
    FROM p
  )
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'promotions'), 'has_data', has_promo,
    'kpi', jsonb_build_object('active', count(*) FILTER (WHERE phase = 'active'), 'upcoming', count(*) FILTER (WHERE phase = 'upcoming'), 'ended_30d', count(*) FILTER (WHERE phase = 'ended'),
      'negative_margin', count(*) FILTER (WHERE min_margin_after_pct < 0)),
    'items', COALESCE(jsonb_agg(jsonb_build_object('id', id, 'promo_id', promo_id, 'type', promo_type, 'name', name, 'asins', asins, 'start_at', start_at, 'end_at', end_at, 'discount_type', discount_type, 'discount_value', discount_value,
        'budget', budget, 'status', status, 'phase', phase, 'margin_note', margin_note, 'min_margin_after_pct', round(min_margin_after_pct, 1),
        'units_in_daily', CASE WHEN days_in > 0 THEN round(units_in::numeric / days_in, 1) END, 'units_pre_daily', CASE WHEN days_pre > 0 THEN round(units_pre::numeric / days_pre, 1) END,
        'lift_pct', CASE WHEN days_in > 0 AND days_pre > 0 AND units_pre > 0 THEN round(100 * ((units_in::numeric / days_in) - (units_pre::numeric / days_pre)) / (units_pre::numeric / days_pre), 1) END)
        ORDER BY CASE phase WHEN 'active' THEN 0 WHEN 'upcoming' THEN 1 ELSE 2 END, start_at), '[]'::jsonb))
  INTO g FROM per;
  res := res || jsonb_build_object('promotions', g);

  -- ---------- 8. REVIEWS ----------
  WITH rv AS (SELECT r.*, COALESCE(r.reviewed_at::date, r.created_at::date) d FROM public.raw_reviews r WHERE r.tenant_id = t),
  k AS (SELECT count(*) FILTER (WHERE d BETWEEN d7 AND d1) n7, count(*) FILTER (WHERE d BETWEEN d30 AND d1) n30, round(AVG(rating) FILTER (WHERE d BETWEEN d30 AND d1), 2) avg30, round(AVG(rating) FILTER (WHERE d BETWEEN b30s AND b30e), 2) avgb,
              count(*) FILTER (WHERE d BETWEEN d7 AND d1 AND rating <= COALESCE((th->>'review_max_rating')::int, 3)) low7 FROM rv),
  low AS (
    SELECT rv.id, rv.asin, rv.rating, left(rv.title, 80) title, left(rv.body, 200) body, rv.d,
           (SELECT array_agg(topic_code) FROM public.review_classifications c WHERE c.review_id = rv.id) topics,
           EXISTS (SELECT 1 FROM public.returns rt WHERE rt.tenant_id = t AND rt.asin = rv.asin AND rt.return_date BETWEEN rv.d - 14 AND rv.d + 14) has_nearby_return
    FROM rv WHERE rv.d BETWEEN d30 AND d1 AND rv.rating <= COALESCE((th->>'review_max_rating')::int, 3) ORDER BY rv.d DESC LIMIT 40
  )
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'reviews'), 'has_data', has_rev,
    'kpi', jsonb_build_object('count_7d', n7, 'count_30d', n30, 'avg_rating_30d', avg30, 'avg_rating_baseline', avgb, 'low_7d', low7),
    'items', COALESCE((SELECT jsonb_agg(to_jsonb(low) ORDER BY d DESC) FROM low), '[]'::jsonb))
  INTO g FROM k;
  res := res || jsonb_build_object('reviews', g);

  -- ---------- 9. ADVERTISING ----------
  WITH a AS (SELECT * FROM public.ad_daily WHERE tenant_id = t AND date BETWEEN b30s AND d1),
  k AS (SELECT SUM(spend) FILTER (WHERE date BETWEEN d7 AND d1) sp7, SUM(sales) FILTER (WHERE date BETWEEN d7 AND d1) sa7, SUM(clicks) FILTER (WHERE date BETWEEN d7 AND d1) cl7, SUM(impressions) FILTER (WHERE date BETWEEN d7 AND d1) im7,
              SUM(spend) FILTER (WHERE date BETWEEN d30 AND d1) sp30, SUM(sales) FILTER (WHERE date BETWEEN d30 AND d1) sa30, SUM(spend) FILTER (WHERE date BETWEEN b30s AND b30e) spb, SUM(sales) FILTER (WHERE date BETWEEN b30s AND b30e) sab
         FROM a WHERE level = (SELECT CASE WHEN EXISTS (SELECT 1 FROM a WHERE level = 'asin') THEN 'asin' ELSE (SELECT level FROM a LIMIT 1) END)),
  per AS (
    SELECT a.asin, k2.title, k2.inventory_qty, SUM(spend) FILTER (WHERE date BETWEEN d7 AND d1) sp7, SUM(sales) FILTER (WHERE date BETWEEN d7 AND d1) sa7, SUM(clicks) FILTER (WHERE date BETWEEN d7 AND d1) cl7, SUM(orders) FILTER (WHERE date BETWEEN d7 AND d1) od7,
           SUM(spend) FILTER (WHERE date BETWEEN b30s AND b30e) spb, SUM(sales) FILTER (WHERE date BETWEEN b30s AND b30e) sab
    FROM a LEFT JOIN public.amazon_skus k2 ON k2.tenant_id = t AND k2.asin = a.asin WHERE a.level = 'asin' GROUP BY a.asin, k2.title, k2.inventory_qty
  ), rev AS (SELECT SUM(COALESCE(item_sales,0)) r7 FROM public.orders WHERE tenant_id = t AND NOT is_cancelled AND order_date BETWEEN d7 AND d1)
  SELECT jsonb_build_object('badge', public.feed_badge(t, 'ads_daily'), 'has_data', has_ads,
    'kpi', jsonb_build_object('spend_7d', sp7, 'sales_7d', sa7, 'acos_7d_pct', CASE WHEN sa7 > 0 THEN round(100 * sp7 / sa7, 1) END, 'spend_30d', sp30, 'sales_30d', sa30,
      'acos_30d_pct', CASE WHEN sa30 > 0 THEN round(100 * sp30 / sa30, 1) END, 'acos_baseline_pct', CASE WHEN sab > 0 THEN round(100 * spb / sab, 1) END,
      'tacos_7d_pct', CASE WHEN (SELECT r7 FROM rev) > 0 THEN round(100 * sp7 / (SELECT r7 FROM rev), 1) END, 'clicks_7d', cl7, 'ctr_7d_pct', CASE WHEN im7 > 0 THEN round(100.0 * cl7 / im7, 2) END),
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('asin', asin, 'title', title, 'inventory_qty', inventory_qty, 'spend_7d', sp7, 'sales_7d', sa7, 'clicks_7d', cl7, 'orders_7d', od7,
        'acos_7d_pct', CASE WHEN sa7 > 0 THEN round(100 * sp7 / sa7, 1) END, 'acos_baseline_pct', CASE WHEN sab > 0 THEN round(100 * spb / sab, 1) END,
        'flag', CASE WHEN inv_known AND inventory_qty = 0 AND sp7 > 0 THEN 'spend_while_oos' WHEN sp7 >= COALESCE((th->>'ads_spend_no_sales_usd')::numeric, 20) AND COALESCE(sa7,0) = 0 THEN 'spend_no_sales'
                     WHEN sa7 > 0 AND 100 * sp7 / sa7 > COALESCE((th->>'acos_max_pct')::numeric, 35) THEN 'acos_high' ELSE 'ok' END) ORDER BY sp7 DESC NULLS LAST) FROM per), '[]'::jsonb))
  INTO g FROM k;
  res := res || jsonb_build_object('advertising', g);

  RETURN res || jsonb_build_object('asof', asof, 'thresholds', th, 'generated_at', now());
END; $$;
GRANT EXECUTE ON FUNCTION public.ops_cockpit(UUID, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 3. cockpit_actions — hàng đợi P0–P3 (xác định, có bằng chứng). Không tự thực thi.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cockpit_actions(t UUID, asof DATE DEFAULT CURRENT_DATE - 1)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE c JSONB; th JSONB; out_ JSONB := '[]'::jsonb; it JSONB; sla JSONB;
BEGIN
  c := public.ops_cockpit(t, asof);
  th := c->'thresholds';
  SELECT COALESCE(sla_hours, '{"P0":4,"P1":24,"P2":72,"P3":168}'::jsonb) INTO sla FROM public.policy_register WHERE tenant_id = t;
  sla := COALESCE(sla, '{"P0":4,"P1":24,"P2":72,"P3":168}'::jsonb);

  -- Helper inline: thêm mục
  -- (PL/pgSQL không có closure → lặp lại jsonb_build_object; giữ cấu trúc thống nhất)

  -- Inventory: critical → P0 nếu DOC < 7, P1 nếu < doc_critical
  FOR it IN SELECT * FROM jsonb_array_elements(c->'inventory'->'items') LOOP
    IF (it->>'inventory_health') = 'critical' THEN
      out_ := out_ || jsonb_build_object('key', 'inv_critical:' || (it->>'asin'), 'group', 'inventory', 'priority', CASE WHEN (it->>'days_of_cover')::numeric < 7 THEN 'P0' ELSE 'P1' END,
        'title', format('Sắp hết hàng %s — còn %s ngày', it->>'asin', it->>'days_of_cover'), 'owner_role', 'ops_lead', 'task_type', 'inventory_investigation',
        'evidence', jsonb_build_object('available', it->'available', 'inbound', it->'inbound', 'velocity_7d', it->'velocity_7d', 'days_of_cover', it->'days_of_cover', 'stockout_eta', it->'stockout_eta'),
        'suggestion', 'Kiểm tra PO/inbound; cân nhắc giảm ngân sách quảng cáo cho ASIN này (đề xuất, không tự thực thi)', 'link', '/inventory', 'asin', it->>'asin');
    END IF;
    IF (it->>'unfulfillable')::int >= COALESCE((th->>'unfulfillable_min')::int, 5) THEN
      out_ := out_ || jsonb_build_object('key', 'inv_unfulfillable:' || (it->>'asin'), 'group', 'inventory', 'priority', 'P2', 'title', format('%s đơn vị unfulfillable — %s', it->>'unfulfillable', it->>'asin'),
        'owner_role', 'operator', 'task_type', 'inventory_investigation', 'evidence', jsonb_build_object('unfulfillable', it->'unfulfillable', 'ledger_date', it->'ledger_date'),
        'suggestion', 'Tạo removal order / kiểm tra lý do hư hỏng trên Seller Central', 'link', '/inventory', 'asin', it->>'asin');
    END IF;
  END LOOP;

  -- Ads
  FOR it IN SELECT * FROM jsonb_array_elements(c->'advertising'->'items') LOOP
    IF (it->>'flag') = 'spend_while_oos' THEN
      out_ := out_ || jsonb_build_object('key', 'ads_oos:' || (it->>'asin'), 'group', 'advertising', 'priority', 'P0', 'title', format('Đang chi quảng cáo cho ASIN hết hàng %s ($%s / 7 ngày)', it->>'asin', it->>'spend_7d'),
        'owner_role', 'operator', 'task_type', 'ads_guardrail', 'evidence', jsonb_build_object('spend_7d', it->'spend_7d', 'inventory_qty', it->'inventory_qty'), 'suggestion', 'Tạm dừng campaign/ad group của ASIN (thực hiện tay trên Ads console, xác nhận kèm bằng chứng)', 'link', '/recommendations', 'asin', it->>'asin');
    ELSIF (it->>'flag') = 'spend_no_sales' THEN
      out_ := out_ || jsonb_build_object('key', 'ads_nosales:' || (it->>'asin'), 'group', 'advertising', 'priority', 'P1', 'title', format('$%s chi 7 ngày, 0 doanh thu QC — %s', it->>'spend_7d', it->>'asin'),
        'owner_role', 'operator', 'task_type', 'ads_guardrail', 'evidence', jsonb_build_object('spend_7d', it->'spend_7d', 'clicks_7d', it->'clicks_7d'), 'suggestion', 'Rà targeting/negative; kiểm tra listing có Buy Box', 'link', '/recommendations', 'asin', it->>'asin');
    ELSIF (it->>'flag') = 'acos_high' THEN
      out_ := out_ || jsonb_build_object('key', 'ads_acos:' || (it->>'asin'), 'group', 'advertising', 'priority', 'P2', 'title', format('ACOS %s%% vượt ngưỡng %s%% — %s', it->>'acos_7d_pct', th->>'acos_max_pct', it->>'asin'),
        'owner_role', 'operator', 'task_type', 'ads_guardrail', 'evidence', jsonb_build_object('acos_7d_pct', it->'acos_7d_pct', 'acos_baseline_pct', it->'acos_baseline_pct', 'spend_7d', it->'spend_7d'), 'suggestion', 'Giảm bid keyword ACOS cao 10–15% (đề xuất)', 'link', '/recommendations', 'asin', it->>'asin');
    END IF;
  END LOOP;

  -- Keywords
  FOR it IN SELECT * FROM jsonb_array_elements(c->'keywords'->'items') LOOP
    IF (it->>'kind') = 'harvest' THEN
      out_ := out_ || jsonb_build_object('key', 'kw_harvest:' || md5(it->>'search_term'), 'group', 'keywords', 'priority', 'P2', 'title', format('Từ khoá chuyển đổi chưa có exact: "%s" (%s đơn / 30 ngày)', it->>'search_term', it->>'orders'),
        'owner_role', 'operator', 'task_type', 'keyword_opportunity', 'evidence', jsonb_build_object('orders', it->'orders', 'clicks', it->'clicks', 'spend', it->'spend', 'sales', it->'sales', 'campaigns', it->'campaigns'), 'suggestion', 'Thêm exact match vào campaign manual; theo dõi 14 ngày', 'link', '/cockpit#keywords');
    ELSIF (it->>'kind') = 'negative' THEN
      out_ := out_ || jsonb_build_object('key', 'kw_negative:' || md5(it->>'search_term'), 'group', 'keywords', 'priority', 'P2', 'title', format('"%s": %s click, 0 đơn, $%s lãng phí', it->>'search_term', it->>'clicks', it->>'spend'),
        'owner_role', 'operator', 'task_type', 'ads_guardrail', 'evidence', jsonb_build_object('clicks', it->'clicks', 'spend', it->'spend', 'campaigns', it->'campaigns'), 'suggestion', 'Thêm negative exact (đề xuất)', 'link', '/cockpit#keywords');
    END IF;
  END LOOP;

  -- Returns: rate > ngưỡng hoặc > baseline × x
  FOR it IN SELECT * FROM jsonb_array_elements(c->'returns'->'items') LOOP
    IF (it->>'rate_pct')::numeric >= COALESCE((th->>'return_rate_pct')::numeric, 8) AND (it->>'q30')::int >= 3 THEN
      out_ := out_ || jsonb_build_object('key', 'ret_rate:' || (it->>'asin'), 'group', 'returns', 'priority', CASE WHEN (it->>'rate_pct')::numeric >= 2 * COALESCE((th->>'return_rate_pct')::numeric, 8) THEN 'P1' ELSE 'P2' END,
        'title', format('Tỷ lệ trả hàng %s%% (%s/%s) — %s', it->>'rate_pct', it->>'q30', it->>'u30', it->>'asin'), 'owner_role', 'content_qa', 'task_type', 'qa_product',
        'evidence', jsonb_build_object('rate_pct', it->'rate_pct', 'top_reasons', it->'top_reasons', 'comments', it->'comments'), 'suggestion', 'Đối chiếu lý do trả với nội dung listing (kích thước/chất liệu); mở QA sản phẩm nếu DEFECTIVE', 'link', '/reviews', 'asin', it->>'asin');
    END IF;
  END LOOP;

  -- Conversion
  FOR it IN SELECT * FROM jsonb_array_elements(c->'conversion'->'items') LOOP
    IF (it->>'diagnosis') = 'buy_box' THEN
      out_ := out_ || jsonb_build_object('key', 'cvr_bb:' || (it->>'asin'), 'group', 'conversion', 'priority', 'P1', 'title', format('Mất Buy Box (%s%%) — %s', it->>'buy_box_pct', it->>'asin'), 'owner_role', 'ops_lead', 'task_type', 'conversion_diagnosis',
        'evidence', jsonb_build_object('buy_box_pct', it->'buy_box_pct', 'sessions_7d', it->'sessions_7d', 'cvr_7d_pct', it->'cvr_7d_pct'), 'suggestion', 'Kiểm tra giá/đối thủ trên listing, tình trạng tài khoản', 'link', '/skus', 'asin', it->>'asin');
    ELSIF (it->>'diagnosis') = 'content_or_price' THEN
      out_ := out_ || jsonb_build_object('key', 'cvr_drop:' || (it->>'asin'), 'group', 'conversion', 'priority', 'P2', 'title', format('CVR giảm %s%% so với baseline — %s', it->>'change_pct', it->>'asin'), 'owner_role', 'content_qa', 'task_type', 'conversion_diagnosis',
        'evidence', jsonb_build_object('cvr_7d_pct', it->'cvr_7d_pct', 'cvr_baseline_pct', it->'cvr_baseline_pct', 'sessions_7d', it->'sessions_7d', 'rating_30d', it->'rating_30d'), 'suggestion', 'Rà ảnh chính/bullets/giá so với đối thủ; xem review mới', 'link', '/content', 'asin', it->>'asin');
    END IF;
  END LOOP;

  -- Traffic drop
  FOR it IN SELECT * FROM jsonb_array_elements(c->'traffic'->'items') LOOP
    IF (it->>'change_pct')::numeric <= -COALESCE((th->>'sessions_drop_pct')::numeric, 30) AND (it->>'sessions_baseline')::int >= 100 THEN
      out_ := out_ || jsonb_build_object('key', 'traffic_drop:' || (it->>'asin'), 'group', 'traffic', 'priority', 'P2', 'title', format('Sessions giảm %s%% so với baseline — %s', it->>'change_pct', it->>'asin'), 'owner_role', 'operator', 'task_type', 'conversion_diagnosis',
        'evidence', jsonb_build_object('sessions_7d', it->'sessions_7d', 'sessions_baseline', it->'sessions_baseline', 'paid_share_pct', it->'paid_share_pct'), 'suggestion', 'Kiểm tra ngân sách QC hết sớm, thứ hạng từ khoá chính, suppressed listing', 'link', '/cockpit#traffic', 'asin', it->>'asin');
    END IF;
  END LOOP;

  -- Orders drop (tenant-level) → P1
  IF (c->'orders'->'kpi'->>'change_7d_vs_baseline_pct')::numeric <= -COALESCE((th->>'orders_drop_pct')::numeric, 30) AND (c->'orders'->'kpi'->>'coverage_7d')::int >= 5 THEN
    out_ := out_ || jsonb_build_object('key', 'orders_drop', 'group', 'orders', 'priority', 'P1', 'title', format('Đơn/ngày 7 ngày giảm %s%% so với 30 ngày trước', c->'orders'->'kpi'->>'change_7d_vs_baseline_pct'), 'owner_role', 'ops_lead', 'task_type', 'other',
      'evidence', c->'orders'->'kpi', 'suggestion', 'Xem nhóm Traffic/Conversion để tách nguyên nhân', 'link', '/cockpit#orders');
  END IF;

  -- Promotions: biên âm hoặc sắp bắt đầu không có ghi chú biên
  FOR it IN SELECT * FROM jsonb_array_elements(c->'promotions'->'items') LOOP
    IF (it->>'min_margin_after_pct')::numeric < 0 AND (it->>'phase') IN ('active','upcoming') THEN
      out_ := out_ || jsonb_build_object('key', 'promo_margin:' || (it->>'promo_id'), 'group', 'promotions', 'priority', 'P1', 'title', format('KM %s làm biên âm (%s%%)', it->>'promo_id', it->>'min_margin_after_pct'), 'owner_role', 'finance', 'task_type', 'promo_review',
        'evidence', jsonb_build_object('discount_type', it->'discount_type', 'discount_value', it->'discount_value', 'asins', it->'asins', 'min_margin_after_pct', it->'min_margin_after_pct'), 'suggestion', 'Xem lại mức giảm hoặc loại ASIN biên thấp', 'link', '/cockpit#promotions');
    ELSIF (it->>'phase') = 'upcoming' AND (it->>'margin_note') IS NULL THEN
      out_ := out_ || jsonb_build_object('key', 'promo_note:' || (it->>'promo_id'), 'group', 'promotions', 'priority', 'P3', 'title', format('KM %s sắp chạy chưa có ghi chú biên', it->>'promo_id'), 'owner_role', 'finance', 'task_type', 'promo_review',
        'evidence', jsonb_build_object('start_at', it->'start_at', 'asins', it->'asins'), 'suggestion', 'Bổ sung ghi chú biên trước khi chạy', 'link', '/import');
    END IF;
  END LOOP;

  -- Reviews: review thấp có return gần đó → P1 (tín hiệu chất lượng)
  FOR it IN SELECT * FROM jsonb_array_elements(c->'reviews'->'items') LOOP
    IF (it->>'has_nearby_return')::boolean AND (it->>'rating')::int <= 2 THEN
      out_ := out_ || jsonb_build_object('key', 'review_quality:' || (it->>'id'), 'group', 'reviews', 'priority', 'P1', 'title', format('Review %s★ + trả hàng cùng kỳ — %s', it->>'rating', it->>'asin'), 'owner_role', 'content_qa', 'task_type', 'qa_product',
        'evidence', jsonb_build_object('review_id', it->'id', 'body', it->'body', 'topics', it->'topics'), 'suggestion', 'Mở ticket VOC, đối chiếu lý do trả hàng; không phản hồi review để xin sửa sao', 'link', '/reviews', 'asin', it->>'asin');
    END IF;
  END LOOP;

  -- Data quality: feed bắt buộc missing/stale → P1/P2 (missing ≠ zero)
  FOR it IN SELECT jsonb_build_object('g', key, 'b', value->'badge') FROM jsonb_each(c) WHERE key IN ('orders','inventory','traffic','advertising','returns') LOOP
    IF (it->'b'->>'status') = 'missing' THEN
      out_ := out_ || jsonb_build_object('key', 'dq_missing:' || (it->>'g'), 'group', 'data_quality', 'priority', CASE WHEN (it->>'g') IN ('orders','inventory') THEN 'P1' ELSE 'P2' END, 'title', format('Chưa có dữ liệu %s — các chỉ số nhóm này KHÔNG phải bằng 0', it->'b'->>'label'),
        'owner_role', 'operator', 'task_type', 'other', 'evidence', it->'b', 'suggestion', 'Nhập CSV hoặc kết nối API', 'link', '/import');
    ELSIF (it->'b'->>'status') = 'stale' THEN
      out_ := out_ || jsonb_build_object('key', 'dq_stale:' || (it->>'g'), 'group', 'data_quality', 'priority', 'P2', 'title', format('Dữ liệu %s quá hạn (tới %s)', it->'b'->>'label', it->'b'->>'last_data_date'),
        'owner_role', 'operator', 'task_type', 'other', 'evidence', it->'b', 'suggestion', 'Cập nhật dữ liệu trước khi ra quyết định', 'link', '/settings/data-sources');
    END IF;
  END LOOP;

  -- deadline theo SLA policy + trạng thái task đã mở
  RETURN (SELECT COALESCE(jsonb_agg(x || jsonb_build_object('deadline', now() + make_interval(hours => COALESCE((sla->>(x->>'priority'))::int, 72)),
      'task_id', (SELECT id FROM public.tasks tk WHERE tk.tenant_id = t AND tk.dedupe_key = x->>'key' AND tk.status IN ('open','in_progress','blocked') LIMIT 1))
      ORDER BY CASE x->>'priority' WHEN 'P0' THEN 0 WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END, x->>'group'), '[]'::jsonb)
    FROM jsonb_array_elements(out_) x);
END; $$;
GRANT EXECUTE ON FUNCTION public.cockpit_actions(UUID, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 4. cockpit_open_task — người dùng bấm "Mở task" (không tự động)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cockpit_open_task(t UUID, p_action JSONB, p_assignee UUID DEFAULT NULL)
RETURNS public.tasks LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tk public.tasks; v_sku UUID; sla JSONB;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT (public.has_permission(t, 'exception.resolve') OR public.has_permission(t, 'voc.triage') OR public.has_permission(t, 'content.draft')) THEN
    RAISE EXCEPTION 'Không đủ quyền mở task';
  END IF;
  IF p_action->>'key' IS NULL OR p_action->>'title' IS NULL THEN RAISE EXCEPTION 'action thiếu key/title'; END IF;
  SELECT id INTO v_sku FROM public.amazon_skus WHERE tenant_id = t AND asin = p_action->>'asin' LIMIT 1;
  SELECT COALESCE(sla_hours, '{"P0":4,"P1":24,"P2":72,"P3":168}'::jsonb) INTO sla FROM public.policy_register WHERE tenant_id = t;
  INSERT INTO public.tasks (tenant_id, sku_id, asin, type, title, description, priority, source_type, evidence, assigned_to, due_at, created_by, dedupe_key)
  VALUES (t, v_sku, p_action->>'asin', COALESCE(p_action->>'task_type', 'other'), left(p_action->>'title', 200),
          COALESCE(p_action->>'suggestion', '') || E'\nNhóm: ' || COALESCE(p_action->>'group', '') || E'\nLiên kết: ' || COALESCE(p_action->>'link', ''),
          COALESCE(p_action->>'priority', 'P2'), 'cockpit', jsonb_build_object('cockpit_key', p_action->>'key', 'group', p_action->>'group', 'owner_role', p_action->>'owner_role', 'evidence', p_action->'evidence', 'generated_at', now()),
          p_assignee, now() + make_interval(hours => COALESCE((sla->>COALESCE(p_action->>'priority','P2'))::int, 72)), auth.uid(), p_action->>'key')
  ON CONFLICT (tenant_id, dedupe_key) WHERE dedupe_key IS NOT NULL AND status IN ('open','in_progress','blocked') DO UPDATE SET updated_at = now()
  RETURNING * INTO tk;
  RETURN tk;
END; $$;
GRANT EXECUTE ON FUNCTION public.cockpit_open_task(UUID, JSONB, UUID) TO authenticated;

DO $$ BEGIN RAISE NOTICE '024 self-check: ops_cockpit=% cockpit_actions=% cockpit_open_task=%',
  to_regprocedure('public.ops_cockpit(uuid,date)') IS NOT NULL, to_regprocedure('public.cockpit_actions(uuid,date)') IS NOT NULL, to_regprocedure('public.cockpit_open_task(uuid,jsonb,uuid)') IS NOT NULL; END $$;
