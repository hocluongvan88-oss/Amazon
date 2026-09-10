-- ============================================================
-- 005 — Data contract (Tuần 1‑2)
--   policy_register · cogs_history · kpi_baseline · import_jobs
--   gán cấp duyệt từ policy · gate "sẵn sàng dữ liệu"
-- Chạy SAU 004. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 0. write_audit_log — bản chắc chắn hơn (dùng JSONB, không tham chiếu
--    trực tiếp NEW.resolved / rec.id nên chạy được trên mọi bảng).
--    PHẢI định nghĩa trước vì các bước dưới kích hoạt trigger audit.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.write_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rec_j     JSONB := to_jsonb(COALESCE(NEW, OLD));
  act       TEXT  := lower(TG_OP);
  before_j  JSONB := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
  after_j   JSONB := CASE WHEN TG_OP IN ('UPDATE','INSERT') THEN to_jsonb(NEW) END;
  ent_id    UUID  := NULLIF(rec_j ->> 'id', '')::uuid;
BEGIN
  IF TG_TABLE_NAME = 'recommendations' AND TG_OP = 'UPDATE' AND (after_j->>'status') IS DISTINCT FROM (before_j->>'status') THEN
    act := 'status:' || (after_j->>'status');
  ELSIF TG_TABLE_NAME = 'exceptions' AND TG_OP = 'UPDATE' AND (after_j->>'resolved') IS DISTINCT FROM (before_j->>'resolved') THEN
    act := CASE WHEN (after_j->>'resolved')::boolean THEN 'resolve' ELSE 'reopen' END;
  END IF;

  INSERT INTO public.audit_log (tenant_id, actor_id, actor_email, entity_type, entity_id, action, before, after, payload)
  VALUES (
    (rec_j ->> 'tenant_id')::uuid, auth.uid(), auth.jwt() ->> 'email', TG_TABLE_NAME, ent_id, act,
    before_j, after_j,
    CASE WHEN TG_OP = 'UPDATE' THEN
      (SELECT jsonb_object_agg(k, after_j -> k) FROM jsonb_object_keys(after_j) k
        WHERE after_j -> k IS DISTINCT FROM before_j -> k AND k NOT IN ('updated_at','updated_by'))
    END
  );
  RETURN COALESCE(NEW, OLD);
END; $$;


-- ------------------------------------------------------------
-- 1. policy_register — ngưỡng vận hành theo brand (1 dòng / tenant)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.policy_register (
  tenant_id                   UUID PRIMARY KEY REFERENCES public.tenants(id) ON DELETE CASCADE,
  -- Cấp duyệt theo risk_score: <= l0_max → L0 ; <= l1_max → L1 ; còn lại L2
  risk_l0_max                 NUMERIC(5,2) NOT NULL DEFAULT 20  CHECK (risk_l0_max BETWEEN 0 AND 100),
  risk_l1_max                 NUMERIC(5,2) NOT NULL DEFAULT 60  CHECK (risk_l1_max BETWEEN 0 AND 100),
  -- Điều chỉnh giá: |Δ%| <= l0 → L0 ; > l2 → L2 bắt buộc ; vượt max → chặn
  price_change_l0_pct         NUMERIC(5,2) NOT NULL DEFAULT 2,
  price_change_l2_pct         NUMERIC(5,2) NOT NULL DEFAULT 5,
  price_change_max_pct        NUMERIC(5,2) NOT NULL DEFAULT 15,
  min_margin_pct              NUMERIC(5,2) NOT NULL DEFAULT 10,   -- không cho giá làm biên CP < mức này
  -- Ngoại lệ (P‑level) theo rủi ro hết hàng / margin
  stockout_p0                 NUMERIC(5,2) NOT NULL DEFAULT 95,
  stockout_p1                 NUMERIC(5,2) NOT NULL DEFAULT 80,
  stockout_p2                 NUMERIC(5,2) NOT NULL DEFAULT 60,
  margin_drop_p1_pct          NUMERIC(5,2) NOT NULL DEFAULT 5,    -- margin Δ âm quá mức này → P1
  -- Trọng số risk score tổng hợp (tuần 5‑6 dùng)
  risk_weights                JSONB NOT NULL DEFAULT '{"margin_delta":0.30,"inventory_health":0.35,"velocity":0.20,"volatility":0.15}'::jsonb,
  -- Tồn kho
  default_lead_time_days      INTEGER NOT NULL DEFAULT 30,
  safety_stock_days           INTEGER NOT NULL DEFAULT 14,
  -- Gate dữ liệu
  data_readiness_target_pct   NUMERIC(5,2) NOT NULL DEFAULT 90,
  revenue_tolerance_pct       NUMERIC(5,2) NOT NULL DEFAULT 2,    -- sai lệch đối soát cho phép
  updated_by                  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (risk_l0_max <= risk_l1_max),
  CHECK (price_change_l0_pct <= price_change_l2_pct AND price_change_l2_pct <= price_change_max_pct),
  CHECK (stockout_p2 <= stockout_p1 AND stockout_p1 <= stockout_p0)
);

CREATE OR REPLACE FUNCTION public.set_policy_meta()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); NEW.updated_by := auth.uid(); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_policy_meta ON public.policy_register;
CREATE TRIGGER trg_policy_meta BEFORE INSERT OR UPDATE ON public.policy_register
  FOR EACH ROW EXECUTE FUNCTION public.set_policy_meta();

-- Mỗi tenant có 1 dòng policy mặc định
INSERT INTO public.policy_register (tenant_id)
SELECT id FROM public.tenants ON CONFLICT (tenant_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.create_default_policy()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.policy_register (tenant_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_tenants_default_policy ON public.tenants;
CREATE TRIGGER trg_tenants_default_policy AFTER INSERT ON public.tenants
  FOR EACH ROW EXECUTE FUNCTION public.create_default_policy();

-- ------------------------------------------------------------
-- 2. amazon_skus — bổ sung cột data contract
-- ------------------------------------------------------------
ALTER TABLE public.amazon_skus
  ADD COLUMN IF NOT EXISTS lead_time_days   INTEGER,
  ADD COLUMN IF NOT EXISTS supplier         TEXT,
  ADD COLUMN IF NOT EXISTS revenue_last_30d NUMERIC(14,2),   -- từ Business Report (Ordered Product Sales)
  ADD COLUMN IF NOT EXISTS sessions_last_30d INTEGER,
  ADD COLUMN IF NOT EXISTS cogs_source      TEXT CHECK (cogs_source IN ('manual','csv','api')),
  ADD COLUMN IF NOT EXISTS fee_source       TEXT CHECK (fee_source IN ('manual','csv','api','estimate')),
  ADD COLUMN IF NOT EXISTS cogs_updated_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS fee_updated_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status           TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','archived'));

-- ------------------------------------------------------------
-- 3. cogs_history — lịch sử giá vốn (nguồn sự thật cho COGS)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cogs_history (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku_id         UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  cogs           NUMERIC(12,2) NOT NULL CHECK (cogs >= 0),
  landed_cost    NUMERIC(12,2),            -- tuỳ chọn: COGS + vận chuyển đến kho FBA
  source         TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','csv','api')),
  note           TEXT,
  created_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (sku_id, effective_from)
);
CREATE INDEX IF NOT EXISTS idx_cogs_history_sku ON public.cogs_history(sku_id, effective_from DESC);

-- Khi có bản ghi COGS mới nhất → đồng bộ vào amazon_skus.cogs
CREATE OR REPLACE FUNCTION public.sync_cogs_to_sku()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE latest RECORD;
BEGIN
  SELECT cogs, source INTO latest FROM public.cogs_history
   WHERE sku_id = COALESCE(NEW.sku_id, OLD.sku_id) AND effective_from <= CURRENT_DATE
   ORDER BY effective_from DESC LIMIT 1;
  IF latest IS NOT NULL THEN
    UPDATE public.amazon_skus SET cogs = latest.cogs, cogs_source = latest.source, cogs_updated_at = now()
     WHERE id = COALESCE(NEW.sku_id, OLD.sku_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END; $$;
DROP TRIGGER IF EXISTS trg_cogs_history_sync ON public.cogs_history;
CREATE TRIGGER trg_cogs_history_sync AFTER INSERT OR UPDATE OR DELETE ON public.cogs_history
  FOR EACH ROW EXECUTE FUNCTION public.sync_cogs_to_sku();

DROP TRIGGER IF EXISTS trg_cogs_history_created_by ON public.cogs_history;
CREATE TRIGGER trg_cogs_history_created_by BEFORE INSERT ON public.cogs_history
  FOR EACH ROW EXECUTE FUNCTION public.set_created_by();

-- Seed lịch sử từ COGS hiện có (nếu chưa có)
INSERT INTO public.cogs_history (tenant_id, sku_id, effective_from, cogs, source, note)
SELECT s.tenant_id, s.id, CURRENT_DATE, s.cogs, 'manual', 'khởi tạo từ dữ liệu hiện có'
FROM public.amazon_skus s
WHERE s.cogs > 0 AND NOT EXISTS (SELECT 1 FROM public.cogs_history h WHERE h.sku_id = s.id)
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 4. kpi_baseline — chốt KPI trước pilot để đo incremental
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_baseline (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  label                 TEXT NOT NULL DEFAULT 'baseline',
  period_start          DATE NOT NULL,
  period_end            DATE NOT NULL,
  sku_count             INTEGER NOT NULL,
  units                 INTEGER NOT NULL,
  revenue               NUMERIC(14,2) NOT NULL,
  contribution_profit   NUMERIC(14,2) NOT NULL,
  cp_margin_pct         NUMERIC(6,2),
  inventory_units       INTEGER,
  avg_days_of_cover     NUMERIC(8,1),
  skus_at_risk          INTEGER,
  data_readiness_pct    NUMERIC(5,2),
  snapshot              JSONB,             -- chi tiết từng SKU tại thời điểm chốt
  captured_by           UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  captured_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_active             BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX IF NOT EXISTS idx_kpi_baseline_tenant ON public.kpi_baseline(tenant_id, captured_at DESC);

-- ------------------------------------------------------------
-- 5. import_jobs — nhật ký import CSV
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.import_jobs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('catalog','cogs','sales','inventory','fees')),
  filename      TEXT,
  rows_total    INTEGER NOT NULL DEFAULT 0,
  rows_ok       INTEGER NOT NULL DEFAULT 0,
  rows_failed   INTEGER NOT NULL DEFAULT 0,
  errors        JSONB,                      -- [{row, asin, message}]
  column_map    JSONB,
  created_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_import_jobs_tenant ON public.import_jobs(tenant_id, created_at DESC);
DROP TRIGGER IF EXISTS trg_import_jobs_created_by ON public.import_jobs;
CREATE TRIGGER trg_import_jobs_created_by BEFORE INSERT ON public.import_jobs
  FOR EACH ROW EXECUTE FUNCTION public.set_created_by();

-- ------------------------------------------------------------
-- 6. Gán cấp duyệt từ policy (BEFORE INSERT recommendations)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approval_level_for(
  t UUID, rec_type TEXT, risk NUMERIC, cur NUMERIC, proposed NUMERIC
) RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.policy_register; lvl TEXT; delta_pct NUMERIC;
BEGIN
  SELECT * INTO p FROM public.policy_register WHERE tenant_id = t;
  IF p IS NULL THEN RETURN 'L1'; END IF;

  lvl := CASE WHEN risk <= p.risk_l0_max THEN 'L0'
              WHEN risk <= p.risk_l1_max THEN 'L1'
              ELSE 'L2' END;

  IF rec_type = 'price_adjust' AND cur IS NOT NULL AND cur > 0 AND proposed IS NOT NULL THEN
    delta_pct := abs(proposed - cur) / cur * 100;
    IF delta_pct > p.price_change_max_pct THEN
      RAISE EXCEPTION 'Thay đổi giá %.1f%% vượt giới hạn chính sách %.1f%%', delta_pct, p.price_change_max_pct;
    ELSIF delta_pct > p.price_change_l2_pct THEN lvl := 'L2';
    ELSIF delta_pct > p.price_change_l0_pct AND lvl = 'L0' THEN lvl := 'L1';
    END IF;
  END IF;
  -- review_response: chỉ triage, luôn cần con người → tối thiểu L1
  IF rec_type = 'review_response' AND lvl = 'L0' THEN lvl := 'L1'; END IF;
  RETURN lvl;
END; $$;

CREATE OR REPLACE FUNCTION public.assign_recommendation_level()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Chỉ tự gán khi client không chỉ định rõ (mặc định cột là 'L1')
  IF TG_OP = 'INSERT' AND (NEW.required_approval_level IS NULL OR NEW.required_approval_level = 'L1') THEN
    NEW.required_approval_level := public.approval_level_for(
      NEW.tenant_id, NEW.type, COALESCE(NEW.risk_score, 0), NEW.current_value, NEW.proposed_value);
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_recommendations_level ON public.recommendations;
CREATE TRIGGER trg_recommendations_level BEFORE INSERT ON public.recommendations
  FOR EACH ROW EXECUTE FUNCTION public.assign_recommendation_level();

-- ------------------------------------------------------------
-- 7. Gate "sẵn sàng dữ liệu"
--    % doanh thu 30 ngày của các SKU có đủ COGS>0, phí FBA>0, referral>0
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_sku_data_quality WITH (security_invoker = true) AS
SELECT
  s.id, s.tenant_id, s.asin, s.sku, s.title, s.status,
  COALESCE(s.revenue_last_30d, s.current_price * s.sales_last_30d) AS revenue_30d,
  s.sales_last_30d,
  (s.cogs > 0)                                    AS has_cogs,
  (s.fee_per_unit > 0)                            AS has_fba_fee,
  (s.referral_fee_pct > 0)                        AS has_referral,
  (s.current_price > 0)                           AS has_price,
  (s.lead_time_days IS NOT NULL)                  AS has_lead_time,
  (s.cogs > 0 AND s.fee_per_unit > 0 AND s.referral_fee_pct > 0 AND s.current_price > 0) AS cp_ready,
  s.cogs_updated_at, s.fee_updated_at, s.last_ingested_at
FROM public.amazon_skus s
WHERE s.status = 'active';
GRANT SELECT ON public.v_sku_data_quality TO authenticated;

CREATE OR REPLACE VIEW public.v_data_readiness WITH (security_invoker = true) AS
SELECT
  q.tenant_id,
  COUNT(*)                                         AS sku_total,
  COUNT(*) FILTER (WHERE q.cp_ready)               AS sku_ready,
  COUNT(*) FILTER (WHERE NOT q.has_cogs)           AS missing_cogs,
  COUNT(*) FILTER (WHERE NOT q.has_fba_fee)        AS missing_fba_fee,
  COUNT(*) FILTER (WHERE NOT q.has_referral)       AS missing_referral,
  COUNT(*) FILTER (WHERE NOT q.has_lead_time)      AS missing_lead_time,
  COUNT(*) FILTER (WHERE q.sales_last_30d = 0)     AS no_sales_data,
  COALESCE(SUM(q.revenue_30d), 0)                  AS revenue_total,
  COALESCE(SUM(q.revenue_30d) FILTER (WHERE q.cp_ready), 0) AS revenue_ready,
  CASE WHEN COALESCE(SUM(q.revenue_30d), 0) > 0
       THEN ROUND(100 * SUM(q.revenue_30d) FILTER (WHERE q.cp_ready) / SUM(q.revenue_30d), 1)
       ELSE 0 END                                  AS readiness_pct,
  p.data_readiness_target_pct                      AS target_pct,
  (CASE WHEN COALESCE(SUM(q.revenue_30d), 0) > 0
        THEN 100 * SUM(q.revenue_30d) FILTER (WHERE q.cp_ready) / SUM(q.revenue_30d) ELSE 0 END)
        >= p.data_readiness_target_pct             AS gate_passed
FROM public.v_sku_data_quality q
JOIN public.policy_register p ON p.tenant_id = q.tenant_id
GROUP BY q.tenant_id, p.data_readiness_target_pct;
GRANT SELECT ON public.v_data_readiness TO authenticated;

-- ------------------------------------------------------------
-- 8. RPC: chốt baseline KPI (owner/operator)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.capture_kpi_baseline(t UUID, lbl TEXT DEFAULT 'baseline')
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE new_id UUID; r RECORD; dr RECORD;
BEGIN
  IF NOT public.has_role(t, ARRAY['owner','operator']) THEN
    RAISE EXCEPTION 'Không đủ quyền chốt baseline';
  END IF;
  SELECT COUNT(*) AS n, COALESCE(SUM(sales_last_30d),0) AS units,
         COALESCE(SUM(COALESCE(revenue_last_30d, current_price*sales_last_30d)),0) AS rev,
         COALESCE(SUM(contribution_profit*sales_last_30d),0) AS cp,
         COALESCE(SUM(inventory_qty),0) AS inv,
         COUNT(*) FILTER (WHERE stockout_risk_score >= 60) AS at_risk,
         AVG(CASE WHEN sales_last_30d > 0 THEN inventory_qty/(sales_last_30d/30.0) END) AS doc,
         jsonb_agg(jsonb_build_object('asin',asin,'price',current_price,'cogs',cogs,'fee',fee_per_unit,
                    'units',sales_last_30d,'cp',contribution_profit,'inv',inventory_qty,'risk',stockout_risk_score)) AS snap
    INTO r FROM public.amazon_skus WHERE tenant_id = t AND status = 'active';
  SELECT readiness_pct INTO dr FROM public.v_data_readiness WHERE tenant_id = t;

  UPDATE public.kpi_baseline SET is_active = FALSE WHERE tenant_id = t AND label = lbl;
  INSERT INTO public.kpi_baseline (tenant_id, label, period_start, period_end, sku_count, units, revenue,
    contribution_profit, cp_margin_pct, inventory_units, avg_days_of_cover, skus_at_risk, data_readiness_pct, snapshot, captured_by)
  VALUES (t, lbl, CURRENT_DATE - 30, CURRENT_DATE, r.n, r.units, r.rev, r.cp,
    CASE WHEN r.rev > 0 THEN ROUND(100*r.cp/r.rev,2) END, r.inv, ROUND(r.doc::numeric,1), r.at_risk,
    dr.readiness_pct, r.snap, auth.uid())
  RETURNING id INTO new_id;
  RETURN new_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.capture_kpi_baseline(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 9. RLS
-- ------------------------------------------------------------
ALTER TABLE public.policy_register ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cogs_history    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_baseline    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.import_jobs     ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies
           WHERE schemaname='public' AND tablename IN ('policy_register','cogs_history','kpi_baseline','import_jobs')
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP;
END $$;

CREATE POLICY policy_select ON public.policy_register FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY policy_update_owner ON public.policy_register FOR UPDATE TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner']));

CREATE POLICY cogs_select ON public.cogs_history FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY cogs_write ON public.cogs_history FOR ALL TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner','operator']))
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));

CREATE POLICY baseline_select ON public.kpi_baseline FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));

CREATE POLICY import_select ON public.import_jobs FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY import_insert ON public.import_jobs FOR INSERT TO authenticated
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));

-- Audit cho policy & cogs
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['policy_register','cogs_history']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()', t, t);
  END LOOP;
END $$;

-- Kiểm tra nhanh
SELECT * FROM public.v_data_readiness;
