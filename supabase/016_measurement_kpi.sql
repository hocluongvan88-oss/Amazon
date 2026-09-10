-- ============================================================
-- 016 — P0‑6: Sổ đo lường thống nhất + KPI content/AI
--   measurements (baseline đóng băng, control, confounder, confidence, đóng băng sau 28 ngày)
--   measure_subject() cho action | content_version  ·  content_kpi()  ·  ai_quality_kpi()
--   pilot_scorecard_v2() = pilot_scorecard + content + ai_quality + measured_cp (chỉ moderate/high)
-- Nguyên tắc (đã chốt): KHÔNG chia attribution khi có thay đổi đồng thời → confidence = confounded,
--   incremental CP không được cộng vào North Star; con người quyết định.
-- Chạy SAU 015. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. measurements
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.measurements (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  subject_type         TEXT NOT NULL CHECK (subject_type IN ('action','content_version')),
  subject_id           UUID NOT NULL,
  sku_id               UUID REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  asin                 TEXT,
  change_at            TIMESTAMPTZ NOT NULL,          -- thời điểm thay đổi (finished_at / published_at)
  window_days          INT NOT NULL,
  method               TEXT NOT NULL DEFAULT 'pre_post_control_v1',
  metric               TEXT NOT NULL DEFAULT 'contribution_profit', -- content: thêm cvr trong observed
  baseline             JSONB NOT NULL,                -- kỳ trước — đóng băng
  observed             JSONB NOT NULL,                -- kỳ sau
  control              JSONB,                         -- {n, cp_before, cp_after, change_pct}
  concurrent_changes   JSONB NOT NULL DEFAULT '[]'::jsonb,
  data_quality         JSONB NOT NULL DEFAULT '{}'::jsonb, -- {orders_fresh, ads_fresh, days_before, days_after}
  incremental_cp_per_day NUMERIC(12,2),
  incremental_cp_total NUMERIC(14,2),
  ci_low               NUMERIC(14,2),
  ci_high              NUMERIC(14,2),
  cvr_delta_pct        NUMERIC(8,2),
  confidence           TEXT NOT NULL CHECK (confidence IN ('insufficient_data','low','confounded','moderate','high')),
  attributable_share   NUMERIC(4,3) CHECK (attributable_share IS NULL OR (attributable_share BETWEEN 0 AND 1)),
  note                 TEXT,
  is_final             BOOLEAN NOT NULL DEFAULT false,
  finalized_at         TIMESTAMPTZ,
  measured_by          UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  measured_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (subject_type, subject_id, window_days)
);
CREATE INDEX IF NOT EXISTS idx_meas_tenant ON public.measurements(tenant_id, measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_meas_sku ON public.measurements(sku_id, change_at DESC);

-- Bản ghi final là bất biến (trừ note)
CREATE OR REPLACE FUNCTION public.measurements_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.is_final THEN
    IF to_jsonb(NEW) - 'note' IS DISTINCT FROM to_jsonb(OLD) - 'note' THEN
      RAISE EXCEPTION 'Bản đo lường đã đóng băng (final) — không được sửa số liệu';
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.attributable_share IS DISTINCT FROM OLD.attributable_share THEN
    RAISE EXCEPTION 'Không gán attributable_share thủ công (quyết định: báo confounded, không chia)';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_measurements_guard ON public.measurements;
CREATE TRIGGER trg_measurements_guard BEFORE UPDATE ON public.measurements FOR EACH ROW EXECUTE FUNCTION public.measurements_guard();

-- ------------------------------------------------------------
-- 2. measure_subject — tính & ghi (upsert khi chưa final)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.measure_subject(p_type TEXT, p_id UUID, p_days INT DEFAULT 14)
RETURNS public.measurements LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  m public.measurements; t UUID; v_sku UUID; asin_ TEXT; d0 TIMESTAMPTZ; dd DATE; existing public.measurements;
  b RECORD; a RECORD; c RECORD; conc JSONB := '[]'::jsonb; n INT; se NUMERIC; ctrl_ratio NUMERIC := 1; inc NUMERIC; conf TEXT; note_ TEXT;
  orders_fresh BOOLEAN; ads_fresh BOOLEAN; cvr_d NUMERIC; base_units NUMERIC;
BEGIN
  IF p_days NOT IN (7, 14, 28) THEN RAISE EXCEPTION 'window_days phải là 7, 14 hoặc 28'; END IF;
  IF p_type = 'action' THEN
    SELECT tenant_id, sku_id, asin, finished_at INTO t, v_sku, asin_, d0 FROM public.actions WHERE id = p_id AND mode <> 'dry_run' AND status IN ('succeeded','rolled_back');
    IF t IS NULL THEN RAISE EXCEPTION 'Action không tồn tại / dry‑run / chưa hoàn tất'; END IF;
  ELSIF p_type = 'content_version' THEN
    SELECT v.tenant_id, v.sku_id, k.asin, v.published_at INTO t, v_sku, asin_, d0 FROM public.content_versions v JOIN public.amazon_skus k ON k.id = v.sku_id WHERE v.id = p_id;
    IF t IS NULL OR d0 IS NULL THEN RAISE EXCEPTION 'Content chưa publish'; END IF;
  ELSE RAISE EXCEPTION 'subject_type không hợp lệ'; END IF;
  IF auth.uid() IS NOT NULL AND NOT (t IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;

  SELECT * INTO existing FROM public.measurements WHERE subject_type = p_type AND subject_id = p_id AND window_days = p_days;
  IF existing.id IS NOT NULL AND existing.is_final THEN RETURN existing; END IF;
  dd := d0::date;

  -- Kỳ trước / kỳ sau (bỏ ngày thay đổi)
  SELECT COUNT(*) AS days, COALESCE(SUM(units),0) AS units, COALESCE(SUM(sessions),0) AS sessions,
         AVG(units * contribution_profit) AS cp_day, STDDEV_SAMP(units * contribution_profit) AS cp_sd,
         AVG(price) AS price, COALESCE(SUM(ad_spend),0) AS ad_spend, COUNT(*) FILTER (WHERE inventory_qty = 0) AS oos_days
    INTO b FROM public.sku_daily_snapshots WHERE sku_id = v_sku AND units IS NOT NULL AND date BETWEEN dd - p_days AND dd - 1;
  SELECT COUNT(*) AS days, COALESCE(SUM(units),0) AS units, COALESCE(SUM(sessions),0) AS sessions,
         AVG(units * contribution_profit) AS cp_day, STDDEV_SAMP(units * contribution_profit) AS cp_sd,
         AVG(price) AS price, COALESCE(SUM(ad_spend),0) AS ad_spend, COUNT(*) FILTER (WHERE inventory_qty = 0) AS oos_days
    INTO a FROM public.sku_daily_snapshots WHERE sku_id = v_sku AND units IS NOT NULL AND date BETWEEN dd + 1 AND dd + p_days;

  -- Đối chứng: ASIN active cùng tenant, không có action thật / content publish trong cửa sổ
  SELECT AVG(x.cp) FILTER (WHERE x.date < dd) AS cpb, AVG(x.cp) FILTER (WHERE x.date > dd) AS cpa, COUNT(DISTINCT x.sku_id) AS n INTO c
  FROM (
    SELECT s.sku_id, s.date, s.units * s.contribution_profit AS cp FROM public.sku_daily_snapshots s
    JOIN public.amazon_skus k ON k.id = s.sku_id AND k.status = 'active'
    WHERE s.tenant_id = t AND s.sku_id <> v_sku AND s.units IS NOT NULL AND s.contribution_profit IS NOT NULL AND s.date BETWEEN dd - p_days AND dd + p_days AND s.date <> dd
      AND NOT EXISTS (SELECT 1 FROM public.actions x WHERE x.sku_id = s.sku_id AND x.mode <> 'dry_run' AND x.status IN ('succeeded','rolled_back') AND x.finished_at::date BETWEEN dd - p_days AND dd + p_days)
      AND NOT EXISTS (SELECT 1 FROM public.content_versions x WHERE x.sku_id = s.sku_id AND x.published_at::date BETWEEN dd - p_days AND dd + p_days)
  ) x;

  -- Thay đổi đồng thời trên chính ASIN (mọi loại; loại trừ chính subject)
  SELECT count(*) INTO n FROM public.actions x WHERE x.sku_id = v_sku AND x.mode <> 'dry_run' AND x.status IN ('succeeded','rolled_back') AND x.id <> p_id AND x.finished_at::date BETWEEN dd - p_days AND dd + p_days;
  IF n > 0 THEN conc := conc || jsonb_build_object('type','action','n',n,'msg',format('%s lệnh thật khác (giá/tồn kho) trong cửa sổ', n)); END IF;
  SELECT count(*) INTO n FROM public.content_versions x WHERE x.sku_id = v_sku AND x.id <> p_id AND x.published_at::date BETWEEN dd - p_days AND dd + p_days;
  IF n > 0 THEN conc := conc || jsonb_build_object('type','content','n',n,'msg',format('%s content khác publish trong cửa sổ', n)); END IF;
  IF b.price IS NOT NULL AND a.price IS NOT NULL AND abs(a.price - b.price) / NULLIF(b.price,0) > 0.02 THEN conc := conc || jsonb_build_object('type','price','msg',format('Giá TB %s → %s', round(b.price,2), round(a.price,2))); END IF;
  IF b.ad_spend > 0 AND abs(a.ad_spend - b.ad_spend) / b.ad_spend > 0.2 THEN conc := conc || jsonb_build_object('type','ads','msg',format('Chi phí ads %s%%', round((a.ad_spend - b.ad_spend) / b.ad_spend * 100))); END IF;
  IF b.oos_days + a.oos_days > 0 THEN conc := conc || jsonb_build_object('type','stock','msg',format('%s ngày hết hàng trong cửa sổ', b.oos_days + a.oos_days)); END IF;
  -- Mùa vụ: đối chứng biến động > 30% → gắn cờ
  IF c.n >= 2 AND c.cpb <> 0 AND abs(c.cpa / c.cpb - 1) > 0.3 THEN conc := conc || jsonb_build_object('type','seasonality','msg',format('Danh mục đối chứng biến động %s%% — nghi mùa vụ/thị trường', round((c.cpa / c.cpb - 1) * 100))); END IF;

  orders_fresh := public.feed_is_fresh(t, 'orders_daily');
  ads_fresh := public.feed_is_fresh(t, 'ads_daily');

  IF c.n >= 2 AND c.cpb IS NOT NULL AND c.cpb <> 0 THEN ctrl_ratio := c.cpa / c.cpb; END IF;
  IF b.cp_day IS NOT NULL AND a.cp_day IS NOT NULL THEN
    inc := a.cp_day - b.cp_day * ctrl_ratio;
    se := sqrt(COALESCE(b.cp_sd,0)^2 / GREATEST(b.days,1) + COALESCE(a.cp_sd,0)^2 / GREATEST(a.days,1));
  END IF;
  cvr_d := CASE WHEN b.sessions > 0 AND a.sessions > 0 AND b.units > 0 THEN round(((a.units::numeric / a.sessions) / (b.units::numeric / b.sessions) - 1) * 100, 2) END;

  conf := CASE
    WHEN b.days < GREATEST(3, p_days / 2) OR a.days < GREATEST(3, p_days / 2) OR NOT orders_fresh THEN 'insufficient_data'
    WHEN jsonb_array_length(conc) > 0 THEN 'confounded'
    WHEN p_type = 'content_version' AND (b.sessions < 200 OR a.sessions < 200) THEN 'low'
    WHEN c.n < 2 THEN 'low'
    WHEN inc IS NOT NULL AND inc <> 0 AND (inc - 1.96 * COALESCE(se,0) > 0 OR inc + 1.96 * COALESCE(se,0) < 0) THEN 'high'
    ELSE 'moderate' END;
  note_ := CASE conf
    WHEN 'insufficient_data' THEN CASE WHEN NOT orders_fresh THEN 'Feed đơn hàng chưa tươi — không kết luận' ELSE format('Chưa đủ ngày dữ liệu (%s trước / %s sau)', b.days, a.days) END
    WHEN 'confounded' THEN 'Có thay đổi đồng thời — KHÔNG gán toàn bộ thay đổi cho hành động này; không cộng vào North Star'
    WHEN 'low' THEN CASE WHEN c.n < 2 THEN 'Không có nhóm đối chứng đủ lớn — so sánh trước/sau thuần' ELSE 'Sessions < 200 mỗi kỳ' END
    WHEN 'high' THEN format('Đối chứng %s ASIN; CI 95%% không chứa 0', c.n)
    ELSE format('Đối chứng %s ASIN; CI 95%% chứa 0 — hướng tích cực nhưng chưa chắc chắn', c.n) END;

  INSERT INTO public.measurements (tenant_id, subject_type, subject_id, sku_id, asin, change_at, window_days, baseline, observed, control, concurrent_changes, data_quality,
      incremental_cp_per_day, incremental_cp_total, ci_low, ci_high, cvr_delta_pct, confidence, note, measured_by)
  VALUES (t, p_type, p_id, v_sku, asin_, d0, p_days,
      jsonb_build_object('from', dd - p_days, 'to', dd - 1, 'days', b.days, 'units', b.units, 'sessions', b.sessions, 'cp_per_day', round(b.cp_day,2), 'avg_price', round(b.price,2), 'ad_spend', b.ad_spend, 'cvr', CASE WHEN b.sessions > 0 THEN round(b.units::numeric / b.sessions, 4) END),
      jsonb_build_object('from', dd + 1, 'to', dd + p_days, 'days', a.days, 'units', a.units, 'sessions', a.sessions, 'cp_per_day', round(a.cp_day,2), 'avg_price', round(a.price,2), 'ad_spend', a.ad_spend, 'cvr', CASE WHEN a.sessions > 0 THEN round(a.units::numeric / a.sessions, 4) END),
      CASE WHEN c.n >= 2 THEN jsonb_build_object('n', c.n, 'cp_before', round(c.cpb,2), 'cp_after', round(c.cpa,2), 'change_pct', round((ctrl_ratio - 1) * 100, 1)) END,
      conc, jsonb_build_object('orders_fresh', orders_fresh, 'ads_fresh', ads_fresh, 'days_before', b.days, 'days_after', a.days),
      round(inc,2), round(inc * a.days,2), round(inc - 1.96 * se,2), round(inc + 1.96 * se,2), cvr_d, conf, note_, auth.uid())
  ON CONFLICT (subject_type, subject_id, window_days) DO UPDATE SET
      change_at = EXCLUDED.change_at, baseline = EXCLUDED.baseline, observed = EXCLUDED.observed, control = EXCLUDED.control, concurrent_changes = EXCLUDED.concurrent_changes, data_quality = EXCLUDED.data_quality,
      incremental_cp_per_day = EXCLUDED.incremental_cp_per_day, incremental_cp_total = EXCLUDED.incremental_cp_total, ci_low = EXCLUDED.ci_low, ci_high = EXCLUDED.ci_high,
      cvr_delta_pct = EXCLUDED.cvr_delta_pct, confidence = EXCLUDED.confidence, note = EXCLUDED.note, measured_by = EXCLUDED.measured_by, measured_at = now()
  RETURNING * INTO m;
  RETURN m;
END; $$;
GRANT EXECUTE ON FUNCTION public.measure_subject(TEXT, UUID, INT) TO authenticated;

-- Đo tất cả subject của tenant (idempotent; bỏ qua bản final)
CREATE OR REPLACE FUNCTION public.measure_all(t UUID, p_days INT DEFAULT 14)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD; n INT := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT (t IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  FOR r IN SELECT id FROM public.actions WHERE tenant_id = t AND mode <> 'dry_run' AND status IN ('succeeded','rolled_back') AND finished_at < now() - interval '3 days' LOOP
    BEGIN PERFORM public.measure_subject('action', r.id, p_days); n := n + 1; EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  FOR r IN SELECT id FROM public.content_versions WHERE tenant_id = t AND published_at IS NOT NULL AND published_at < now() - interval '3 days' LOOP
    BEGIN PERFORM public.measure_subject('content_version', r.id, p_days); n := n + 1; EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.measure_all(UUID, INT) TO authenticated;

-- Đóng băng: change_at + window + 28 ngày đã qua và không còn insufficient_data → final
CREATE OR REPLACE FUNCTION public.finalize_measurements(t UUID)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT (t IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  -- đo lại lần cuối trước khi đóng
  PERFORM public.measure_subject(subject_type, subject_id, window_days) FROM public.measurements
   WHERE tenant_id = t AND NOT is_final AND change_at + make_interval(days => window_days + 28) < now();
  UPDATE public.measurements SET is_final = true, finalized_at = now()
   WHERE tenant_id = t AND NOT is_final AND change_at + make_interval(days => window_days + 28) < now() AND confidence <> 'insufficient_data';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.finalize_measurements(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 3. KPI content (từ content_versions / product_facts / measurements)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.content_kpi(t UUID, p_days INT DEFAULT 30)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH v AS (
    SELECT * FROM public.content_versions WHERE tenant_id = t AND created_at > now() - make_interval(days => p_days)
  ), pub AS (
    SELECT * FROM public.content_versions WHERE tenant_id = t AND published_at > now() - make_interval(days => p_days)
  ), blocked AS (
    -- từng bị qa_blocked (theo audit_log)
    SELECT DISTINCT entity_id FROM public.audit_log WHERE tenant_id = t AND entity_type = 'content_versions' AND created_at > now() - make_interval(days => p_days) AND (after->>'status') = 'qa_blocked'
  ), m AS (
    SELECT * FROM public.measurements WHERE tenant_id = t AND subject_type = 'content_version'
  )
  SELECT jsonb_build_object(
    'window_days', p_days,
    'drafts_created', (SELECT count(*) FROM v),
    'ai_drafts', (SELECT count(*) FROM v WHERE origin = 'ai_draft'),
    'published', (SELECT count(*) FROM pub),
    'in_flight', (SELECT count(*) FROM public.content_versions WHERE tenant_id = t AND status IN ('qa_review','qa_passed','awaiting_brand_approval','approved')),
    'awaiting_brand', (SELECT count(*) FROM public.content_versions WHERE tenant_id = t AND status = 'awaiting_brand_approval'),
    'first_pass_qa_pct', (SELECT round(100.0 * count(*) FILTER (WHERE id NOT IN (SELECT entity_id FROM blocked)) / NULLIF(count(*),0)) FROM v WHERE qa_at IS NOT NULL),
    'compliance_block_pct', (SELECT round(100.0 * count(*) FILTER (WHERE COALESCE((compliance->>'blocks')::int,0) > 0) / NULLIF(count(*),0)) FROM v),
    'compliance_override_count', (SELECT count(*) FROM v WHERE compliance_override_reason IS NOT NULL),
    'published_with_evidence_pct', (SELECT round(100.0 * count(*) FILTER (WHERE evidence <> '{}'::jsonb) / NULLIF(count(*),0)) FROM pub),
    'published_with_verified_facts_pct', (SELECT round(100.0 * count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.product_facts f WHERE f.sku_id = pub.sku_id AND f.status = 'verified')) / NULLIF(count(*),0)) FROM pub),
    'hours_draft_to_qa', (SELECT round(avg(EXTRACT(EPOCH FROM (qa_at - created_at)) / 3600)::numeric, 1) FROM v WHERE qa_at IS NOT NULL),
    'hours_qa_to_brand', (SELECT round(avg(EXTRACT(EPOCH FROM (brand_at - qa_at)) / 3600)::numeric, 1) FROM v WHERE brand_at IS NOT NULL AND qa_at IS NOT NULL),
    'hours_draft_to_publish', (SELECT round(avg(EXTRACT(EPOCH FROM (published_at - created_at)) / 3600)::numeric, 1) FROM pub),
    'rollbacks', (SELECT count(*) FROM public.content_versions WHERE tenant_id = t AND status = 'rolled_back' AND updated_at > now() - make_interval(days => p_days)),
    'rollback_rate_pct', (SELECT round(100.0 * count(*) FILTER (WHERE status = 'rolled_back') / NULLIF(count(*),0)) FROM public.content_versions WHERE tenant_id = t AND published_at IS NOT NULL AND published_at > now() - make_interval(days => p_days)),
    'measured', (SELECT count(*) FROM m),
    'measured_confident', (SELECT count(*) FROM m WHERE confidence IN ('moderate','high')),
    'measured_confounded', (SELECT count(*) FROM m WHERE confidence = 'confounded'),
    'median_cvr_delta_pct', (SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY cvr_delta_pct))::numeric, 1) FROM m WHERE confidence IN ('moderate','high') AND cvr_delta_pct IS NOT NULL),
    'incremental_cp_confident', (SELECT round(COALESCE(sum(incremental_cp_total),0),2) FROM m WHERE confidence IN ('moderate','high'))
  );
$$;
GRANT EXECUTE ON FUNCTION public.content_kpi(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 4. KPI chất lượng AI / rule (acceptance, override, precision, rollback)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_quality_kpi(t UUID, p_days INT DEFAULT 30)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH recs AS (SELECT * FROM public.recommendations WHERE tenant_id = t AND created_at > now() - make_interval(days => p_days)),
       cv AS (SELECT * FROM public.content_versions WHERE tenant_id = t AND origin = 'ai_draft' AND created_at > now() - make_interval(days => p_days)),
       rd AS (SELECT * FROM public.response_drafts WHERE tenant_id = t AND created_at > now() - make_interval(days => p_days)),
       ex AS (SELECT * FROM public.exceptions WHERE tenant_id = t AND created_at > now() - make_interval(days => p_days)),
       cls AS (SELECT * FROM public.review_classifications WHERE tenant_id = t AND method <> 'human' AND created_at > now() - make_interval(days => p_days)),
       acts AS (SELECT * FROM public.actions WHERE tenant_id = t AND mode <> 'dry_run' AND created_at > now() - make_interval(days => p_days)),
       ms AS (SELECT * FROM public.measurements WHERE tenant_id = t AND subject_type = 'action')
  SELECT jsonb_build_object(
    'window_days', p_days,
    'rec_total', (SELECT count(*) FROM recs),
    'rec_acceptance_pct', (SELECT round(100.0 * count(*) FILTER (WHERE status IN ('approved','executed')) / NULLIF(count(*) FILTER (WHERE status <> 'draft' AND status <> 'pending_approval'),0)) FROM recs),
    'rec_reject_pct', (SELECT round(100.0 * count(*) FILTER (WHERE status = 'rejected') / NULLIF(count(*) FILTER (WHERE status <> 'draft' AND status <> 'pending_approval'),0)) FROM recs),
    'rec_sod_overrides', (SELECT count(*) FROM recs WHERE sod_override_reason IS NOT NULL),
    'rec_with_rationale_pct', (SELECT round(100.0 * count(*) FILTER (WHERE COALESCE(trim(rationale),'') <> '') / NULLIF(count(*),0)) FROM recs),
    'ai_content_drafts', (SELECT count(*) FROM cv),
    'ai_content_accept_pct', (SELECT round(100.0 * count(*) FILTER (WHERE status IN ('approved','published','superseded')) / NULLIF(count(*) FILTER (WHERE status IN ('approved','published','superseded','rejected','rolled_back')),0)) FROM cv),
    'ai_content_rollback_pct', (SELECT round(100.0 * count(*) FILTER (WHERE status = 'rolled_back') / NULLIF(count(*) FILTER (WHERE published_at IS NOT NULL),0)) FROM cv),
    'response_drafts', (SELECT count(*) FROM rd),
    'response_accept_pct', (SELECT round(100.0 * count(*) FILTER (WHERE status IN ('approved','sent')) / NULLIF(count(*) FILTER (WHERE status IN ('approved','sent','rejected')),0)) FROM rd),
    'policy_blocks_response', (SELECT count(*) FROM rd WHERE COALESCE((policy_check->>'ok')::boolean, true) = false),
    'exception_precision_pct', (SELECT round(100.0 * count(*) FILTER (WHERE to_jsonb(ex)->>'feedback' = 'true_positive') / NULLIF(count(*) FILTER (WHERE to_jsonb(ex)->>'feedback' IN ('true_positive','false_positive')),0)) FROM ex),
    'classification_precision_pct', (SELECT round(100.0 * count(*) FILTER (WHERE verified_ok) / NULLIF(count(*) FILTER (WHERE verified_at IS NOT NULL),0)) FROM cls),
    'classification_verified', (SELECT count(*) FILTER (WHERE verified_at IS NOT NULL) FROM cls),
    'actions_real', (SELECT count(*) FROM acts),
    'actions_rolled_back', (SELECT count(*) FROM acts WHERE status = 'rolled_back'),
    'actions_measured', (SELECT count(*) FROM ms),
    'actions_measured_pct', (SELECT round(100.0 * (SELECT count(DISTINCT subject_id) FROM ms) / NULLIF((SELECT count(*) FROM public.actions WHERE tenant_id = t AND mode <> 'dry_run' AND status IN ('succeeded','rolled_back') AND finished_at < now() - interval '3 days'),0))),
    'actions_confident', (SELECT count(*) FROM ms WHERE confidence IN ('moderate','high')),
    'actions_confounded', (SELECT count(*) FROM ms WHERE confidence = 'confounded'),
    'incremental_cp_confident', (SELECT round(COALESCE(sum(incremental_cp_total),0),2) FROM ms WHERE confidence IN ('moderate','high')),
    'incremental_cp_positive_pct', (SELECT round(100.0 * count(*) FILTER (WHERE incremental_cp_total > 0) / NULLIF(count(*),0)) FROM ms WHERE confidence IN ('moderate','high'))
  );
$$;
GRANT EXECUTE ON FUNCTION public.ai_quality_kpi(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 5. Scorecard v2 = v1 + content + ai_quality + measured_cp
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pilot_scorecard_v2(t UUID, p_days INT DEFAULT 14)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE base JSONB; ck JSONB; ak JSONB;
BEGIN
  base := public.pilot_scorecard(t, p_days);
  ck := public.content_kpi(t, 30); ak := public.ai_quality_kpi(t, 30);
  RETURN base || jsonb_build_object(
    'content', ck, 'ai_quality', ak,
    'measured_cp', jsonb_build_object(
      'confident_total', COALESCE((ck->>'incremental_cp_confident')::numeric,0) + COALESCE((ak->>'incremental_cp_confident')::numeric,0),
      'confounded_count', COALESCE((ck->>'measured_confounded')::int,0) + COALESCE((ak->>'actions_confounded')::int,0),
      'rule', 'Chỉ cộng bản đo confidence moderate/high; confounded/low/insufficient hiển thị riêng, không chia attribution'),
    'freshness', public.freshness_summary(t)
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.pilot_scorecard_v2(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 6. RLS + audit
-- ------------------------------------------------------------
ALTER TABLE public.measurements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS meas_select ON public.measurements; DROP POLICY IF EXISTS meas_note ON public.measurements;
CREATE POLICY meas_select ON public.measurements FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
-- chỉ sửa note qua UI; số liệu chỉ qua measure_subject (SECURITY DEFINER)
CREATE POLICY meas_note ON public.measurements FOR UPDATE TO authenticated USING (public.has_permission(tenant_id, 'rec.approve_l1')) WITH CHECK (public.has_permission(tenant_id, 'rec.approve_l1'));
DROP TRIGGER IF EXISTS trg_measurements_audit ON public.measurements;
CREATE TRIGGER trg_measurements_audit AFTER INSERT OR UPDATE OR DELETE ON public.measurements FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- Kiểm tra nhanh:
-- SELECT public.measure_all('<tenant>', 14); SELECT subject_type, asin, confidence, incremental_cp_total, concurrent_changes FROM public.measurements;
