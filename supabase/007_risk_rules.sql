-- ============================================================
-- 007 — Risk score · Rule engine · SLA ngoại lệ · Profit bridge  (Tuần 5‑6)
-- Chạy SAU 006. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Policy: SLA, cooldown, bật/tắt rule
-- ------------------------------------------------------------
ALTER TABLE public.policy_register
  ADD COLUMN IF NOT EXISTS sla_hours     JSONB NOT NULL DEFAULT '{"P0":4,"P1":24,"P2":72,"P3":168}'::jsonb,
  ADD COLUMN IF NOT EXISTS cooldown_days INTEGER NOT NULL DEFAULT 7,
  ADD COLUMN IF NOT EXISTS rule_toggles  JSONB NOT NULL DEFAULT '{}'::jsonb;   -- {"OVERSTOCK":false}

-- ------------------------------------------------------------
-- 2. Risk trên SKU + lịch sử
-- ------------------------------------------------------------
ALTER TABLE public.amazon_skus
  ADD COLUMN IF NOT EXISTS risk_score       NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS risk_components  JSONB,
  ADD COLUMN IF NOT EXISTS risk_computed_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.risk_history (
  sku_id     UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  date       DATE NOT NULL,
  tenant_id  UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  risk_score NUMERIC(5,2) NOT NULL,
  components JSONB,
  PRIMARY KEY (sku_id, date)
);
CREATE INDEX IF NOT EXISTS idx_risk_history_tenant ON public.risk_history(tenant_id, date DESC);

-- ------------------------------------------------------------
-- 3. Ngoại lệ: SLA, feedback, liên kết rule/SKU
-- ------------------------------------------------------------
ALTER TABLE public.exceptions
  ADD COLUMN IF NOT EXISTS rule_code       TEXT,
  ADD COLUMN IF NOT EXISTS sku_id          UUID REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS assigned_to     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS due_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS snoozed_until   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS auto_resolved   BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS feedback        TEXT CHECK (feedback IN ('true_positive','false_positive')),
  ADD COLUMN IF NOT EXISTS feedback_note   TEXT,
  ADD COLUMN IF NOT EXISTS resolution_note TEXT,
  ADD COLUMN IF NOT EXISTS context         JSONB;
CREATE INDEX IF NOT EXISTS idx_exceptions_open_rule ON public.exceptions(tenant_id, sku_id, rule_code) WHERE NOT resolved;

-- due_at mặc định theo SLA của policy
CREATE OR REPLACE FUNCTION public.set_exception_due()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE h INTEGER;
BEGIN
  IF NEW.due_at IS NULL THEN
    SELECT COALESCE((sla_hours ->> NEW.code)::int, 72) INTO h FROM public.policy_register WHERE tenant_id = NEW.tenant_id;
    NEW.due_at := COALESCE(NEW.created_at, now()) + make_interval(hours => COALESCE(h, 72));
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_exceptions_due ON public.exceptions;
CREATE TRIGGER trg_exceptions_due BEFORE INSERT ON public.exceptions
  FOR EACH ROW EXECUTE FUNCTION public.set_exception_due();

UPDATE public.exceptions e SET due_at = e.created_at + make_interval(hours => COALESCE((p.sla_hours ->> e.code)::int, 72))
FROM public.policy_register p WHERE p.tenant_id = e.tenant_id AND e.due_at IS NULL;

-- ------------------------------------------------------------
-- 4. Nội suy tuyến tính theo mốc  pl_interp(x, '[[x0,y0],[x1,y1],...]')
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pl_interp(x NUMERIC, pts JSONB)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE n INT := jsonb_array_length(pts); i INT; x0 NUMERIC; y0 NUMERIC; x1 NUMERIC; y1 NUMERIC;
BEGIN
  IF x IS NULL THEN RETURN NULL; END IF;
  IF x <= (pts->0->>0)::numeric THEN RETURN (pts->0->>1)::numeric; END IF;
  IF x >= (pts->(n-1)->>0)::numeric THEN RETURN (pts->(n-1)->>1)::numeric; END IF;
  FOR i IN 1..n-1 LOOP
    x0 := (pts->(i-1)->>0)::numeric; y0 := (pts->(i-1)->>1)::numeric;
    x1 := (pts->i->>0)::numeric;     y1 := (pts->i->>1)::numeric;
    IF x <= x1 THEN RETURN ROUND(y0 + (y1 - y0) * (x - x0) / NULLIF(x1 - x0, 0), 1); END IF;
  END LOOP;
  RETURN (pts->(n-1)->>1)::numeric;
END; $$;

-- ------------------------------------------------------------
-- 5. compute_risk_score(sku_id) → ghi vào amazon_skus + risk_history
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_risk_score(p_sku UUID)
RETURNS NUMERIC LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  k public.amazon_skus%ROWTYPE; m RECORD; pol public.policy_register%ROWTYPE;
  w_inv NUMERIC; w_mar NUMERIC; w_vel NUMERIC; w_vol NUMERIC;
  s_inv NUMERIC; s_mar NUMERIC; s_vel NUMERIC; s_vol NUMERIC;
  r_inv TEXT; r_mar TEXT; r_vel TEXT; r_vol TEXT;
  need NUMERIC; wsum NUMERIC := 0; total NUMERIC := 0; conf NUMERIC; score NUMERIC; comps JSONB;
BEGIN
  SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  IF k.id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = k.tenant_id;
  SELECT * INTO m FROM public.sku_metrics(k.tenant_id, CURRENT_DATE, p_sku);

  w_inv := COALESCE((pol.risk_weights->>'inventory_health')::numeric, 0.35);
  w_mar := COALESCE((pol.risk_weights->>'margin_delta')::numeric, 0.30);
  w_vel := COALESCE((pol.risk_weights->>'velocity')::numeric, 0.20);
  w_vol := COALESCE((pol.risk_weights->>'volatility')::numeric, 0.15);
  need := COALESCE(k.lead_time_days, pol.default_lead_time_days, 30) + COALESCE(pol.safety_stock_days, 14);

  -- (a) inventory health: dựa trên DoC / need
  IF m.days_of_cover IS NOT NULL THEN
    IF m.days_of_cover > need * 6 THEN
      s_inv := 25; r_inv := format('Tồn dư: %s ngày hàng (> 6× nhu cầu %s ngày)', m.days_of_cover, need);
    ELSE
      s_inv := public.pl_interp(m.days_of_cover / need, '[[0,100],[0.5,85],[1,60],[1.5,30],[3,5]]');
      r_inv := format('%s ngày hàng so với %s ngày cần (lead time + an toàn)', m.days_of_cover, need);
    END IF;
  ELSIF k.inventory_qty = 0 THEN
    s_inv := 100; r_inv := 'Hết hàng (tồn 0)';
  END IF;

  -- (b) margin
  IF m.cp_margin_now_pct IS NOT NULL THEN
    IF m.margin_delta_pts IS NOT NULL THEN
      s_mar := public.pl_interp(m.margin_delta_pts, '[[-10,100],[-5,65],[-2,35],[0,10],[5,5]]');
      r_mar := format('Biên %s%% (Δ %s điểm so với baseline)', m.cp_margin_now_pct, m.margin_delta_pts);
    ELSE
      s_mar := public.pl_interp(m.cp_margin_now_pct, format('[[0,100],[%s,60],[25,10],[40,5]]', pol.min_margin_pct)::jsonb);
      r_mar := format('Biên %s%% (chưa có baseline; mức tối thiểu %s%%)', m.cp_margin_now_pct, pol.min_margin_pct);
    END IF;
    IF m.cp_margin_now_pct < pol.min_margin_pct THEN
      s_mar := GREATEST(s_mar, 70); r_mar := r_mar || ' – dưới biên tối thiểu';
    END IF;
  END IF;

  -- (c) velocity
  IF m.days_since_last_sale IS NOT NULL AND m.days_since_last_sale >= 7 AND COALESCE(m.units_30d, 0) > 0 THEN
    s_vel := 90; r_vel := format('Không bán %s ngày dù 30 ngày bán %s đv', m.days_since_last_sale, m.units_30d);
  ELSIF m.velocity_change_pct IS NOT NULL AND m.coverage_days_30 >= 14 THEN
    IF m.velocity_change_pct > 80 THEN
      s_vel := 40; r_vel := format('Tăng đột biến +%s%% (7d vs 30d) – nguy cơ hết hàng sớm', m.velocity_change_pct);
    ELSE
      s_vel := public.pl_interp(m.velocity_change_pct, '[[-70,100],[-50,85],[-30,55],[-10,20],[0,10],[30,5]]');
      r_vel := format('Tốc độ bán 7d %s đv/ngày vs 30d %s (%s%%)', m.velocity_7d, m.velocity_30d, m.velocity_change_pct);
    END IF;
  END IF;

  -- (d) volatility
  IF m.price_volatility_pct IS NOT NULL AND m.coverage_days_30 >= 14 THEN
    s_vol := public.pl_interp(m.price_volatility_pct, '[[0,0],[3,30],[8,65],[15,100]]');
    r_vol := format('Biến động giá 30 ngày %s%%', m.price_volatility_pct);
  END IF;

  -- tổng có trọng số, chuẩn hoá theo thành phần có dữ liệu
  IF s_inv IS NOT NULL THEN total := total + w_inv * s_inv; wsum := wsum + w_inv; END IF;
  IF s_mar IS NOT NULL THEN total := total + w_mar * s_mar; wsum := wsum + w_mar; END IF;
  IF s_vel IS NOT NULL THEN total := total + w_vel * s_vel; wsum := wsum + w_vel; END IF;
  IF s_vol IS NOT NULL THEN total := total + w_vol * s_vol; wsum := wsum + w_vol; END IF;
  conf := ROUND(wsum / NULLIF(w_inv + w_mar + w_vel + w_vol, 0), 2);
  score := CASE WHEN wsum > 0 THEN ROUND(total / wsum, 1) END;

  comps := jsonb_build_object(
    'inventory',  jsonb_build_object('score', s_inv, 'weight', w_inv, 'reason', r_inv, 'doc', m.days_of_cover, 'need', need, 'eta', m.stockout_eta),
    'margin',     jsonb_build_object('score', s_mar, 'weight', w_mar, 'reason', r_mar, 'margin_pct', m.cp_margin_now_pct, 'delta_pts', m.margin_delta_pts),
    'velocity',   jsonb_build_object('score', s_vel, 'weight', w_vel, 'reason', r_vel, 'v7', m.velocity_7d, 'v30', m.velocity_30d, 'change_pct', m.velocity_change_pct),
    'volatility', jsonb_build_object('score', s_vol, 'weight', w_vol, 'reason', r_vol, 'pct', m.price_volatility_pct),
    'confidence', conf, 'coverage_days', m.coverage_days_30, 'computed_at', now());

  UPDATE public.amazon_skus SET
    risk_score = score, risk_components = comps, risk_computed_at = now(),
    stockout_risk_score = COALESCE(s_inv, stockout_risk_score)
  WHERE id = p_sku;

  IF score IS NOT NULL THEN
    INSERT INTO public.risk_history (sku_id, date, tenant_id, risk_score, components)
    VALUES (p_sku, CURRENT_DATE, k.tenant_id, score, comps)
    ON CONFLICT (sku_id, date) DO UPDATE SET risk_score = EXCLUDED.risk_score, components = EXCLUDED.components;
  END IF;
  RETURN score;
END; $$;

CREATE OR REPLACE FUNCTION public.recompute_all_risk(t UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INTEGER := 0; r RECORD;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_role(t, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
  FOR r IN SELECT id FROM public.amazon_skus WHERE tenant_id = t AND status = 'active' LOOP
    PERFORM public.compute_risk_score(r.id); n := n + 1;
  END LOOP;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.compute_risk_score(UUID), public.recompute_all_risk(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 6. Rule engine
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rule_runs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,
  trigger       TEXT NOT NULL DEFAULT 'manual',
  skus_scanned  INTEGER NOT NULL DEFAULT 0,
  exceptions_opened  INTEGER NOT NULL DEFAULT 0,
  exceptions_closed  INTEGER NOT NULL DEFAULT 0,
  recs_created  INTEGER NOT NULL DEFAULT 0,
  details       JSONB
);
CREATE INDEX IF NOT EXISTS idx_rule_runs_tenant ON public.rule_runs(tenant_id, started_at DESC);

-- helper: mở ngoại lệ nếu chưa có / không trong cooldown ; trả TRUE nếu mở mới
CREATE OR REPLACE FUNCTION public._open_exception(t UUID, p_sku UUID, p_asin TEXT, p_rule TEXT, p_code TEXT, p_msg TEXT, p_ctx JSONB, cooldown INT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.exceptions WHERE tenant_id = t AND rule_code = p_rule AND sku_id IS NOT DISTINCT FROM p_sku AND NOT resolved) THEN
    -- cập nhật mức P & thông điệp nếu leo thang
    UPDATE public.exceptions SET code = LEAST(code, p_code), message = p_msg, context = p_ctx
     WHERE tenant_id = t AND rule_code = p_rule AND sku_id IS NOT DISTINCT FROM p_sku AND NOT resolved AND (code <> p_code OR message <> p_msg);
    RETURN FALSE;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exceptions WHERE tenant_id = t AND rule_code = p_rule AND sku_id IS NOT DISTINCT FROM p_sku
             AND resolved AND NOT auto_resolved AND feedback = 'false_positive' AND resolved_at > now() - make_interval(days => cooldown)) THEN
    RETURN FALSE;
  END IF;
  INSERT INTO public.exceptions (tenant_id, sku_id, asin, rule_code, code, message, context)
  VALUES (t, p_sku, p_asin, p_rule, p_code, p_msg, p_ctx);
  RETURN TRUE;
END; $$;

CREATE OR REPLACE FUNCTION public.run_rules(t UUID, p_trigger TEXT DEFAULT 'manual')
RETURNS public.rule_runs LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  run public.rule_runs; pol public.policy_register%ROWTYPE; k RECORD; m RECORD;
  need NUMERIC; v NUMERIC; qty INTEGER; new_price NUMERIC; ref NUMERIC; cp_new NUMERIC; msg TEXT; rat TEXT; ctx JSONB;
  opened INT := 0; closed INT := 0; recs INT := 0; scanned INT := 0;
  active_rules TEXT[]; still TEXT[]; rc TEXT; ex RECORD; cool INT; conn RECORD; rule_on BOOLEAN;
  rec_exists BOOLEAN; risk NUMERIC; rcomp JSONB;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_role(t, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền chạy rule'; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = t;
  cool := COALESCE(pol.cooldown_days, 7);
  INSERT INTO public.rule_runs (tenant_id, trigger) VALUES (t, p_trigger) RETURNING * INTO run;

  FOR k IN SELECT * FROM public.amazon_skus WHERE tenant_id = t AND status = 'active' LOOP
    scanned := scanned + 1;
    risk := public.compute_risk_score(k.id);
    SELECT risk_components INTO rcomp FROM public.amazon_skus WHERE id = k.id;  -- k là bản chụp trước khi tính
    SELECT * INTO m FROM public.sku_metrics(t, CURRENT_DATE, k.id);
    need := COALESCE(k.lead_time_days, pol.default_lead_time_days, 30) + COALESCE(pol.safety_stock_days, 14);
    v := COALESCE(m.velocity_7d, m.velocity_30d, CASE WHEN k.sales_last_30d > 0 THEN k.sales_last_30d / 30.0 END);
    ref := COALESCE(k.referral_fee_pct, 15) / 100;
    still := ARRAY[]::text[];

    -- ===== STOCKOUT_IMMINENT / BELOW_REORDER_POINT =====
    IF m.days_of_cover IS NOT NULL AND m.days_of_cover < COALESCE(k.lead_time_days, pol.default_lead_time_days, 30) AND COALESCE((pol.rule_toggles->>'STOCKOUT_IMMINENT')::boolean, TRUE) THEN
      still := array_append(still, 'STOCKOUT_IMMINENT'::text);
      qty := GREATEST(0, CEIL(v * need + v * COALESCE(pol.safety_stock_days, 14) - k.inventory_qty))::int;
      msg := format('Sắp hết hàng: còn %s ngày (%s đv, bán %s đv/ngày), lead time %s ngày', m.days_of_cover, k.inventory_qty, ROUND(v,1), COALESCE(k.lead_time_days, pol.default_lead_time_days, 30));
      ctx := jsonb_build_object('doc', m.days_of_cover, 'inventory', k.inventory_qty, 'velocity', v, 'lead_time', COALESCE(k.lead_time_days, pol.default_lead_time_days, 30), 'suggested_qty', qty, 'eta', m.stockout_eta);
      IF public._open_exception(t, k.id, k.asin, 'STOCKOUT_IMMINENT', CASE WHEN m.days_of_cover < 7 THEN 'P0' ELSE 'P1' END, msg, ctx, cool) THEN
        opened := opened + 1;
        SELECT EXISTS (SELECT 1 FROM public.recommendations WHERE sku_id = k.id AND type = 'replenish' AND status IN ('draft','pending_approval','approved')) INTO rec_exists;
        IF NOT rec_exists AND qty > 0 THEN
          rat := format('Tồn %s đv, bán %s đv/ngày (7 ngày) → còn ~%s ngày; cần %s ngày (lead time %s + an toàn %s). Đề xuất nhập %s đv = %s × %s + %s ngày an toàn − %s. Rủi ro %s (tồn kho %s · biên %s · tốc độ %s · biến động %s; tin cậy %s%%).',
            k.inventory_qty, ROUND(v,1), m.days_of_cover, need, COALESCE(k.lead_time_days, pol.default_lead_time_days, 30), COALESCE(pol.safety_stock_days,14), qty, ROUND(v,1), need, COALESCE(pol.safety_stock_days,14), k.inventory_qty,
            risk, COALESCE(rcomp->'inventory'->>'score','n/a'), COALESCE(rcomp->'margin'->>'score','n/a'), COALESCE(rcomp->'velocity'->>'score','n/a'), COALESCE(rcomp->'volatility'->>'score','n/a'), COALESCE(ROUND(100*(rcomp->>'confidence')::numeric)::text,'?'));
          INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, rationale, current_value, proposed_value, expected_impact, risk_score, status)
          VALUES (t, k.id, k.asin, 'replenish', format('Nhập thêm %s đv %s', qty, k.asin), rat, k.inventory_qty, qty,
                  ROUND(v * 30 * k.contribution_profit, 0), COALESCE(risk, 50), 'pending_approval');
          recs := recs + 1;
        END IF;
      END IF;
    ELSIF k.inventory_qty < k.reorder_point AND k.reorder_point > 0 AND COALESCE((pol.rule_toggles->>'BELOW_REORDER_POINT')::boolean, TRUE) THEN
      still := array_append(still, 'BELOW_REORDER_POINT'::text);
      msg := format('Tồn %s dưới điểm đặt hàng lại %s', k.inventory_qty, k.reorder_point);
      IF public._open_exception(t, k.id, k.asin, 'BELOW_REORDER_POINT', 'P2', msg, jsonb_build_object('inventory', k.inventory_qty, 'rop', k.reorder_point), cool) THEN opened := opened + 1; END IF;
    END IF;

    -- ===== OVERSTOCK =====
    IF m.days_of_cover IS NOT NULL AND m.days_of_cover > need * 6 AND k.inventory_qty > 0 AND COALESCE((pol.rule_toggles->>'OVERSTOCK')::boolean, TRUE) THEN
      still := array_append(still, 'OVERSTOCK'::text);
      msg := format('Tồn dư: %s ngày hàng (%s đv) so với nhu cầu %s ngày', m.days_of_cover, k.inventory_qty, need);
      IF public._open_exception(t, k.id, k.asin, 'OVERSTOCK', 'P3', msg, jsonb_build_object('doc', m.days_of_cover, 'need', need), cool) THEN
        opened := opened + 1;
        -- gợi ý giảm giá trong giới hạn, giữ biên tối thiểu
        new_price := ROUND(k.current_price * (1 - pol.price_change_l2_pct / 100), 2);
        cp_new := new_price - k.cogs - k.fee_per_unit - new_price * ref;
        IF new_price > 0 AND cp_new / new_price * 100 >= pol.min_margin_pct THEN
          SELECT EXISTS (SELECT 1 FROM public.recommendations WHERE sku_id = k.id AND type = 'price_adjust' AND status IN ('draft','pending_approval','approved')) INTO rec_exists;
          IF NOT rec_exists THEN
            rat := format('Tồn %s đv = %s ngày hàng, gấp >6 lần nhu cầu %s ngày → vốn đọng. Đề xuất giảm giá %s → %s (−%s%%, trong giới hạn chính sách) để tăng vòng quay; biên sau giảm %s%% (≥ tối thiểu %s%%). Cần theo dõi CVR sau 14 ngày.',
              k.inventory_qty, m.days_of_cover, need, k.current_price, new_price, pol.price_change_l2_pct, ROUND(cp_new/new_price*100,1), pol.min_margin_pct);
            INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, rationale, current_value, proposed_value, expected_impact, risk_score, status)
            VALUES (t, k.id, k.asin, 'price_adjust', format('Giảm giá %s %s → %s', k.asin, k.current_price, new_price), rat, k.current_price, new_price, NULL, COALESCE(risk, 40), 'draft');
            recs := recs + 1;
          END IF;
        END IF;
      END IF;
    END IF;

    -- ===== MARGIN_EROSION =====
    IF m.cp_margin_now_pct IS NOT NULL AND ((m.margin_delta_pts IS NOT NULL AND m.margin_delta_pts <= -pol.margin_drop_p1_pct) OR m.cp_margin_now_pct < pol.min_margin_pct)
       AND COALESCE((pol.rule_toggles->>'MARGIN_EROSION')::boolean, TRUE) THEN
      still := array_append(still, 'MARGIN_EROSION'::text);
      msg := CASE WHEN m.cp_margin_now_pct < pol.min_margin_pct
                  THEN format('Biên lợi nhuận góp phần %s%% dưới mức tối thiểu %s%%', m.cp_margin_now_pct, pol.min_margin_pct)
                  ELSE format('Biên giảm %s điểm so với baseline (hiện %s%%)', m.margin_delta_pts, m.cp_margin_now_pct) END;
      IF public._open_exception(t, k.id, k.asin, 'MARGIN_EROSION', 'P1', msg, jsonb_build_object('margin_pct', m.cp_margin_now_pct, 'delta_pts', m.margin_delta_pts, 'cogs', k.cogs, 'fee', k.fee_per_unit), cool) THEN
        opened := opened + 1;
        -- giá cần để về biên tối thiểu: p = (cogs+fee) / (1 - ref - min%)
        new_price := ROUND((k.cogs + k.fee_per_unit) / NULLIF(1 - ref - GREATEST(pol.min_margin_pct, COALESCE(m.cp_margin_baseline_pct, pol.min_margin_pct)) / 100, 0), 2);
        IF new_price IS NOT NULL AND new_price > k.current_price THEN
          new_price := LEAST(new_price, ROUND(k.current_price * (1 + pol.price_change_l2_pct / 100), 2));
          SELECT EXISTS (SELECT 1 FROM public.recommendations WHERE sku_id = k.id AND type = 'price_adjust' AND status IN ('draft','pending_approval','approved')) INTO rec_exists;
          IF NOT rec_exists THEN
            cp_new := new_price - k.cogs - k.fee_per_unit - new_price * ref;
            rat := format('Biên hiện tại %s%% (COGS %s, phí FBA %s, referral %s%%)%s. Đề xuất tăng giá %s → %s (+%s%%, giới hạn %s%%/lần) → biên %s%%. Kiểm tra giá đối thủ & Buy Box trước khi duyệt; nếu COGS/phí vừa tăng, cân nhắc đàm phán NCC song song.',
              m.cp_margin_now_pct, k.cogs, k.fee_per_unit, k.referral_fee_pct,
              CASE WHEN m.margin_delta_pts IS NOT NULL THEN format(', giảm %s điểm so với baseline', m.margin_delta_pts) ELSE '' END,
              k.current_price, new_price, ROUND((new_price/k.current_price-1)*100,1), pol.price_change_l2_pct, ROUND(cp_new/new_price*100,1));
            INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, rationale, current_value, proposed_value, expected_impact, risk_score, status)
            VALUES (t, k.id, k.asin, 'price_adjust', format('Tăng giá %s %s → %s', k.asin, k.current_price, new_price), rat, k.current_price, new_price,
                    ROUND(v * 30 * (cp_new - k.contribution_profit), 0), COALESCE(risk, 50), 'pending_approval');
            recs := recs + 1;
          END IF;
        END IF;
      END IF;
    END IF;

    -- ===== VELOCITY_DROP =====
    IF m.velocity_change_pct IS NOT NULL AND m.velocity_change_pct <= -30 AND COALESCE(m.units_30d,0) >= 30 AND m.coverage_days_30 >= 14
       AND COALESCE((pol.rule_toggles->>'VELOCITY_DROP')::boolean, TRUE) THEN
      still := array_append(still, 'VELOCITY_DROP'::text);
      msg := format('Tốc độ bán giảm %s%%: %s đv/ngày (7d) vs %s (30d). Kiểm tra: giá vs đối thủ, Buy Box, listing bị đè, hết hàng biến thể, quảng cáo.', ABS(m.velocity_change_pct), m.velocity_7d, m.velocity_30d);
      IF public._open_exception(t, k.id, k.asin, 'VELOCITY_DROP', 'P2', msg, jsonb_build_object('v7', m.velocity_7d, 'v30', m.velocity_30d, 'change_pct', m.velocity_change_pct), cool) THEN opened := opened + 1; END IF;
    END IF;

    -- ===== NO_SALES_7D =====
    IF m.days_since_last_sale IS NOT NULL AND m.days_since_last_sale >= 7 AND COALESCE(m.units_30d,0) >= 10 AND COALESCE((pol.rule_toggles->>'NO_SALES_7D')::boolean, TRUE) THEN
      still := array_append(still, 'NO_SALES_7D'::text);
      msg := format('Không có đơn %s ngày liên tiếp (30 ngày trước bán %s đv). Nghi listing bị ẩn/đè hoặc hết hàng.', m.days_since_last_sale, m.units_30d);
      IF public._open_exception(t, k.id, k.asin, 'NO_SALES_7D', 'P1', msg, jsonb_build_object('days', m.days_since_last_sale, 'u30', m.units_30d), cool) THEN opened := opened + 1; END IF;
    END IF;

    -- ===== PRICE_VOLATILITY =====
    IF m.price_volatility_pct IS NOT NULL AND m.price_volatility_pct >= 8 AND m.coverage_days_30 >= 14 AND COALESCE((pol.rule_toggles->>'PRICE_VOLATILITY')::boolean, TRUE) THEN
      still := array_append(still, 'PRICE_VOLATILITY'::text);
      msg := format('Giá biến động %s%% trong 30 ngày – kiểm tra repricer/khuyến mãi chồng chéo', m.price_volatility_pct);
      IF public._open_exception(t, k.id, k.asin, 'PRICE_VOLATILITY', 'P3', msg, jsonb_build_object('pct', m.price_volatility_pct), cool) THEN opened := opened + 1; END IF;
    END IF;

    -- ===== auto‑resolve các rule SKU không còn đúng =====
    FOR ex IN SELECT id, rule_code FROM public.exceptions WHERE tenant_id = t AND sku_id = k.id AND NOT resolved AND rule_code IS NOT NULL
              AND rule_code NOT IN ('DATA_STALE') LOOP
      IF NOT (ex.rule_code = ANY(still)) THEN
        UPDATE public.exceptions SET resolved = TRUE, resolved_at = now(), auto_resolved = TRUE, resolution_note = 'Điều kiện không còn đúng khi chạy rule' WHERE id = ex.id;
        closed := closed + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- ===== DATA_STALE (cấp brand) =====
  SELECT * INTO conn FROM public.v_data_connections WHERE tenant_id = t;
  IF conn.last_state_snapshot IS NULL OR conn.last_state_snapshot < CURRENT_DATE - 3 OR COALESCE(conn.sales_days_30,0) < 20 THEN
    msg := format('Dữ liệu chưa đủ tươi: snapshot gần nhất %s, %s/30 ngày có dữ liệu bán', COALESCE(conn.last_state_snapshot::text,'chưa có'), COALESCE(conn.sales_days_30,0));
    IF public._open_exception(t, NULL, NULL, 'DATA_STALE', 'P2', msg, to_jsonb(conn), cool) THEN opened := opened + 1; END IF;
  ELSE
    UPDATE public.exceptions SET resolved = TRUE, resolved_at = now(), auto_resolved = TRUE, resolution_note = 'Dữ liệu đã đủ tươi'
     WHERE tenant_id = t AND rule_code = 'DATA_STALE' AND NOT resolved;
  END IF;

  UPDATE public.rule_runs SET finished_at = now(), skus_scanned = scanned, exceptions_opened = opened, exceptions_closed = closed, recs_created = recs
   WHERE id = run.id RETURNING * INTO run;
  RETURN run;
END; $$;
GRANT EXECUTE ON FUNCTION public.run_rules(UUID, TEXT) TO authenticated;

-- Chạy cho mọi tenant (pg_cron)
CREATE OR REPLACE FUNCTION public.run_rules_all()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.tenants LOOP PERFORM public.run_rules(r.id, 'cron'); END LOOP;
END; $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'vexim_daily_rules';
    PERFORM cron.schedule('vexim_daily_rules', '30 3 * * *', $c$ SELECT public.run_rules_all(); $c$);
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron: %', SQLERRM;
END $$;

-- ------------------------------------------------------------
-- 7. Views: hàng đợi SLA + precision theo rule
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_exception_queue WITH (security_invoker = true) AS
SELECT e.*,
       k.title AS sku_title,
       (NOT e.resolved AND e.due_at < now() AND (e.snoozed_until IS NULL OR e.snoozed_until < now())) AS overdue,
       ROUND(EXTRACT(EPOCH FROM (e.due_at - now())) / 3600.0, 1) AS hours_left,
       (e.snoozed_until IS NOT NULL AND e.snoozed_until > now()) AS snoozed
FROM public.exceptions e
LEFT JOIN public.amazon_skus k ON k.id = e.sku_id;
GRANT SELECT ON public.v_exception_queue TO authenticated;

CREATE OR REPLACE VIEW public.v_rule_precision WITH (security_invoker = true) AS
SELECT tenant_id, rule_code,
       COUNT(*) AS opened,
       COUNT(*) FILTER (WHERE feedback = 'true_positive')  AS tp,
       COUNT(*) FILTER (WHERE feedback = 'false_positive') AS fp,
       COUNT(*) FILTER (WHERE auto_resolved) AS auto_closed,
       CASE WHEN COUNT(*) FILTER (WHERE feedback IS NOT NULL) > 0
            THEN ROUND(100.0 * COUNT(*) FILTER (WHERE feedback = 'true_positive') / COUNT(*) FILTER (WHERE feedback IS NOT NULL), 0) END AS precision_pct
FROM public.exceptions WHERE rule_code IS NOT NULL
GROUP BY tenant_id, rule_code;
GRANT SELECT ON public.v_rule_precision TO authenticated;

-- ------------------------------------------------------------
-- 8. Profit bridge
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.profit_bridge(UUID, INTEGER);
CREATE FUNCTION public.profit_bridge(t UUID, days INTEGER DEFAULT 7)
RETURNS TABLE (
  sku_id UUID, asin TEXT, title TEXT,
  units0 BIGINT, units1 BIGINT, cp0 NUMERIC, cp1 NUMERIC, delta NUMERIC,
  d_volume NUMERIC, d_price NUMERIC, d_cogs NUMERIC, d_fees NUMERIC, d_ads NUMERIC,
  cov0 INTEGER, cov1 INTEGER
) LANGUAGE sql STABLE AS $$
WITH p AS (
  SELECT s.sku_id,
    CASE WHEN s.date > CURRENT_DATE - days THEN 1 ELSE 0 END AS per,
    s.units, s.revenue, s.ad_spend,
    COALESCE(s.price, CASE WHEN s.units > 0 THEN s.revenue / s.units END) AS price,
    s.cogs, s.fee_per_unit, s.referral_fee_pct
  FROM public.sku_daily_snapshots s
  WHERE s.tenant_id = t AND s.date > CURRENT_DATE - 2 * days AND s.date <= CURRENT_DATE
),
agg AS (
  SELECT sku_id, per,
    SUM(units) AS u, COUNT(units) AS cov, SUM(COALESCE(ad_spend,0)) AS ads,
    -- trung bình có trọng số theo units (fallback trung bình thường)
    COALESCE(SUM(price * units) / NULLIF(SUM(units),0), AVG(price)) AS p,
    COALESCE(SUM(cogs * units) / NULLIF(SUM(units),0), AVG(cogs)) AS c,
    COALESCE(SUM(fee_per_unit * units) / NULLIF(SUM(units),0), AVG(fee_per_unit)) AS f,
    COALESCE(SUM(referral_fee_pct * units) / NULLIF(SUM(units),0), AVG(referral_fee_pct), 15) / 100 AS r
  FROM p GROUP BY sku_id, per
),
w AS (
  SELECT k.id, k.asin, k.title,
    a0.u AS u0, a1.u AS u1, a0.cov AS cov0, a1.cov AS cov1,
    COALESCE(a0.p, k.current_price) AS p0, COALESCE(a1.p, k.current_price) AS p1,
    COALESCE(a0.c, k.cogs) AS c0, COALESCE(a1.c, k.cogs) AS c1,
    COALESCE(a0.f, k.fee_per_unit) AS f0, COALESCE(a1.f, k.fee_per_unit) AS f1,
    COALESCE(a0.r, k.referral_fee_pct/100) AS r0, COALESCE(a1.r, k.referral_fee_pct/100) AS r1,
    COALESCE(a0.ads,0) AS ads0, COALESCE(a1.ads,0) AS ads1
  FROM public.amazon_skus k
  LEFT JOIN agg a0 ON a0.sku_id = k.id AND a0.per = 0
  LEFT JOIN agg a1 ON a1.sku_id = k.id AND a1.per = 1
  WHERE k.tenant_id = t AND k.status = 'active' AND (a0.u IS NOT NULL OR a1.u IS NOT NULL)
),
calc AS (
  SELECT *,
    (p0 - c0 - f0 - p0*r0) AS cpu0, (p1 - c1 - f1 - p1*r1) AS cpu1,
    COALESCE(u0,0) AS uu0, COALESCE(u1,0) AS uu1
  FROM w
)
SELECT id, asin, title, u0, u1,
  ROUND(uu0 * cpu0 - ads0, 2) AS cp0,
  ROUND(uu1 * cpu1 - ads1, 2) AS cp1,
  ROUND((uu1 * cpu1 - ads1) - (uu0 * cpu0 - ads0), 2) AS delta,
  ROUND((uu1 - uu0) * cpu0, 2)                         AS d_volume,
  ROUND(uu1 * ((p1 - p0) - (p1*r1 - p0*r0)), 2)       AS d_price,   -- giá ròng sau referral
  ROUND(-uu1 * (c1 - c0), 2)                           AS d_cogs,
  ROUND(-uu1 * (f1 - f0), 2)                           AS d_fees,
  ROUND(-(ads1 - ads0), 2)                             AS d_ads,
  COALESCE(cov0,0)::int, COALESCE(cov1,0)::int
FROM calc
ORDER BY ABS((uu1 * cpu1 - ads1) - (uu0 * cpu0 - ads0)) DESC;
$$;
GRANT EXECUTE ON FUNCTION public.profit_bridge(UUID, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 9. RLS
-- ------------------------------------------------------------
ALTER TABLE public.risk_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rule_runs    ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname='public' AND tablename IN ('risk_history','rule_runs')
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP;
END $$;
CREATE POLICY risk_hist_select ON public.risk_history FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY rule_runs_select ON public.rule_runs FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));

-- Chạy lần đầu cho mọi tenant (không cần auth.uid vì gọi từ SQL editor)
SELECT (public.run_rules(id, 'migration')).* FROM public.tenants;
