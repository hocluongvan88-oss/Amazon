-- ============================================================
-- 008 — Forecast baseline · Backtest · Kế hoạch tồn kho · Scenario planner  (Tuần 7‑8)
-- Chạy SAU 007. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Inbound (hàng đang về) trên SKU + snapshot
-- ------------------------------------------------------------
ALTER TABLE public.amazon_skus ADD COLUMN IF NOT EXISTS inventory_inbound INTEGER NOT NULL DEFAULT 0;

-- capture_daily_snapshots: thêm inbound (giữ nguyên chữ ký)
CREATE OR REPLACE FUNCTION public.capture_daily_snapshots(t UUID DEFAULT NULL, d DATE DEFAULT CURRENT_DATE, src TEXT DEFAULT 'cron')
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INTEGER;
BEGIN
  IF auth.uid() IS NOT NULL AND (t IS NULL OR NOT public.has_role(t, ARRAY['owner','operator'])) THEN
    RAISE EXCEPTION 'Không đủ quyền chụp snapshot';
  END IF;
  INSERT INTO public.sku_daily_snapshots AS s
    (sku_id, date, tenant_id, asin, price, cogs, fee_per_unit, referral_fee_pct, contribution_profit,
     inventory_qty, inventory_inbound, reorder_point, sources)
  SELECT k.id, d, k.tenant_id, k.asin, k.current_price, k.cogs, k.fee_per_unit, k.referral_fee_pct, k.contribution_profit,
         k.inventory_qty, k.inventory_inbound, k.reorder_point, jsonb_build_object('state', src)
  FROM public.amazon_skus k
  WHERE k.status = 'active' AND (t IS NULL OR k.tenant_id = t)
  ON CONFLICT (sku_id, date) DO UPDATE SET
    price = EXCLUDED.price, cogs = EXCLUDED.cogs, fee_per_unit = EXCLUDED.fee_per_unit,
    referral_fee_pct = EXCLUDED.referral_fee_pct, contribution_profit = EXCLUDED.contribution_profit,
    inventory_qty = EXCLUDED.inventory_qty, inventory_inbound = EXCLUDED.inventory_inbound, reorder_point = EXCLUDED.reorder_point,
    sources = s.sources || EXCLUDED.sources;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

-- ------------------------------------------------------------
-- 2. Bảng forecast + backtest
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.forecasts (
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku_id    UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  made_on   DATE NOT NULL,           -- ngày lập dự báo
  date      DATE NOT NULL,           -- ngày được dự báo
  horizon   INTEGER NOT NULL,        -- 1 = ngày kế tiếp
  p50       NUMERIC(10,2) NOT NULL,
  p90       NUMERIC(10,2) NOT NULL,
  model     TEXT NOT NULL,
  PRIMARY KEY (sku_id, made_on, date)
);
CREATE INDEX IF NOT EXISTS idx_forecasts_tenant ON public.forecasts(tenant_id, made_on DESC);

CREATE TABLE IF NOT EXISTS public.forecast_backtests (
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku_id    UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  made_on   DATE NOT NULL,
  model     TEXT NOT NULL,
  mape      NUMERIC(6,1) NOT NULL,   -- % sai số tuyệt đối trung bình (cửa sổ 7 ngày)
  bias_pct  NUMERIC(6,1),            -- + = dự báo cao hơn thực tế
  windows   INTEGER NOT NULL,
  chosen    BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (sku_id, made_on, model)
);

-- ------------------------------------------------------------
-- 3. Helper: mức bán/ngày theo mô hình & hệ số ngày trong tuần
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._fc_level(u NUMERIC[], upto INT, model TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s NUMERIC := 0; c INT := 0; i INT; lvl NUMERIC; w INT;
BEGIN
  IF model = 'ses' THEN                          -- simple exponential smoothing, alpha 0.3
    FOR i IN 1..upto LOOP
      IF u[i] IS NOT NULL THEN
        lvl := CASE WHEN lvl IS NULL THEN u[i] ELSE 0.3 * u[i] + 0.7 * lvl END;
      END IF;
    END LOOP;
    RETURN lvl;
  END IF;
  w := CASE model WHEN 'naive7' THEN 7 ELSE 28 END;   -- trung bình trượt
  FOR i IN REVERSE upto..GREATEST(1, upto - w + 1) LOOP
    IF u[i] IS NOT NULL THEN s := s + u[i]; c := c + 1; END IF;
  END LOOP;
  RETURN CASE WHEN c > 0 THEN s / c END;
END; $$;

-- hệ số theo thứ (ISODOW 1..7) từ 56 ngày gần nhất trước "upto"; 1 nếu thiếu dữ liệu
CREATE OR REPLACE FUNCTION public._fc_dow(u NUMERIC[], d DATE[], upto INT)
RETURNS NUMERIC[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE sums NUMERIC[] := array_fill(0::numeric, ARRAY[7]); cnt INT[] := array_fill(0, ARRAY[7]);
        f NUMERIC[] := array_fill(1::numeric, ARRAY[7]); tot NUMERIC := 0; n INT := 0; i INT; k INT; mean NUMERIC;
BEGIN
  FOR i IN REVERSE upto..GREATEST(1, upto - 55) LOOP
    IF u[i] IS NOT NULL THEN
      k := EXTRACT(ISODOW FROM d[i])::int;
      sums[k] := sums[k] + u[i]; cnt[k] := cnt[k] + 1; tot := tot + u[i]; n := n + 1;
    END IF;
  END LOOP;
  IF n < 28 OR tot = 0 THEN RETURN f; END IF;
  mean := tot / n;
  FOR k IN 1..7 LOOP
    IF cnt[k] >= 4 THEN f[k] := LEAST(1.5, GREATEST(0.5, (sums[k] / cnt[k]) / mean)); END IF;
  END LOOP;
  RETURN f;
END; $$;

-- ------------------------------------------------------------
-- 4. forecast_sku: backtest 3 mô hình (naive7 / ma28 / ses_dow) trên cửa sổ 7 ngày,
--    chọn MAPE thấp nhất, ghi p50/p90 cho "horizon" ngày. p90 ≈ p50 × (1 + 1.28 × MAPE).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.forecast_sku(p_sku UUID, asof DATE DEFAULT CURRENT_DATE, horizon INT DEFAULT 56)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  k public.amazon_skus%ROWTYPE; d DATE[]; u NUMERIC[]; n INT := 90; npts INT; i INT; j INT; m TEXT;
  models TEXT[] := ARRAY['naive7','ma28','ses_dow'];
  lvl NUMERIC; f NUMERIC[]; cut INT; fsum NUMERIC; asum NUMERIC; acnt INT;
  ape NUMERIC[]; err NUMERIC[]; wins INT; mape NUMERIC; bias NUMERIC;
  best TEXT; best_mape NUMERIC; sigma NUMERIC := 0.3; dt DATE; p50 NUMERIC; p90 NUMERIC;
BEGIN
  SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  IF k.id IS NULL THEN RETURN NULL; END IF;

  -- chuỗi 90 ngày (asof-90 .. asof-1); ngày asof thường chưa đủ dữ liệu
  SELECT array_agg(g.day::date ORDER BY g.day), array_agg(s.units::numeric ORDER BY g.day)
    INTO d, u
  FROM generate_series(asof - 90, asof - 1, interval '1 day') g(day)
  LEFT JOIN public.sku_daily_snapshots s ON s.sku_id = p_sku AND s.date = g.day::date;
  SELECT count(*) INTO npts FROM unnest(u) x WHERE x IS NOT NULL;

  DELETE FROM public.forecast_backtests WHERE sku_id = p_sku AND made_on = asof;
  DELETE FROM public.forecasts WHERE sku_id = p_sku AND made_on = asof;

  IF npts < 7 THEN
    -- chưa đủ snapshot: dùng số 30 ngày trong danh mục, độ bất định cao
    lvl := CASE WHEN COALESCE(k.sales_last_30d, 0) > 0 THEN k.sales_last_30d / 30.0 ELSE 0 END;
    best := 'catalog_30d'; sigma := 0.5;
  ELSE
    FOREACH m IN ARRAY models LOOP
      ape := ARRAY[]::numeric[]; err := ARRAY[]::numeric[]; wins := 0;
      FOR j IN 1..8 LOOP                       -- tối đa 8 cửa sổ backtest × 7 ngày
        cut := n - 7 * j;
        EXIT WHEN cut < 14;
        lvl := public._fc_level(u, cut, CASE WHEN m = 'ses_dow' THEN 'ses' ELSE m END);
        CONTINUE WHEN lvl IS NULL;
        f := CASE WHEN m = 'ses_dow' THEN public._fc_dow(u, d, cut) ELSE array_fill(1::numeric, ARRAY[7]) END;
        fsum := 0; asum := 0; acnt := 0;
        FOR i IN cut + 1..cut + 7 LOOP
          IF u[i] IS NOT NULL THEN
            fsum := fsum + lvl * f[EXTRACT(ISODOW FROM d[i])::int]; asum := asum + u[i]; acnt := acnt + 1;
          END IF;
        END LOOP;
        IF acnt >= 5 AND asum > 0 THEN
          ape := array_append(ape, abs(fsum - asum) / asum);
          err := array_append(err, (fsum - asum) / asum);
          wins := wins + 1;
        END IF;
      END LOOP;
      IF wins > 0 THEN
        SELECT round(100 * avg(x), 1) INTO mape FROM unnest(ape) x;
        SELECT round(100 * avg(x), 1) INTO bias FROM unnest(err) x;
        INSERT INTO public.forecast_backtests (tenant_id, sku_id, made_on, model, mape, bias_pct, windows)
        VALUES (k.tenant_id, p_sku, asof, m, mape, bias, wins);
        IF best_mape IS NULL OR mape < best_mape THEN best := m; best_mape := mape; END IF;
      END IF;
    END LOOP;
    IF best IS NULL THEN best := 'naive7'; END IF;
    UPDATE public.forecast_backtests SET chosen = TRUE WHERE sku_id = p_sku AND made_on = asof AND model = best;
    lvl := COALESCE(public._fc_level(u, n, CASE WHEN best = 'ses_dow' THEN 'ses' ELSE best END), 0);
    sigma := LEAST(1.0, COALESCE(best_mape / 100.0, 0.3));
  END IF;

  f := CASE WHEN best = 'ses_dow' THEN public._fc_dow(u, d, n) ELSE array_fill(1::numeric, ARRAY[7]) END;
  FOR i IN 0..horizon - 1 LOOP
    dt := asof + i;
    p50 := round(lvl * f[EXTRACT(ISODOW FROM dt)::int], 2);
    p90 := round(p50 * (1 + 1.2816 * sigma), 2);
    INSERT INTO public.forecasts (tenant_id, sku_id, made_on, date, horizon, p50, p90, model)
    VALUES (k.tenant_id, p_sku, asof, dt, i + 1, p50, p90, best);
  END LOOP;
  RETURN best;
END; $$;

CREATE OR REPLACE FUNCTION public.run_forecasts(t UUID, horizon INT DEFAULT 56)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT := 0; r RECORD;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_role(t, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền chạy forecast'; END IF;
  FOR r IN SELECT id FROM public.amazon_skus WHERE tenant_id = t AND status = 'active' LOOP
    PERFORM public.forecast_sku(r.id, CURRENT_DATE, horizon); n := n + 1;
  END LOOP;
  -- dọn forecast cũ hơn 120 ngày
  DELETE FROM public.forecasts WHERE tenant_id = t AND made_on < CURRENT_DATE - 120;
  DELETE FROM public.forecast_backtests WHERE tenant_id = t AND made_on < CURRENT_DATE - 120;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.forecast_sku(UUID, DATE, INT), public.run_forecasts(UUID, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.run_forecasts_all()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.tenants LOOP PERFORM public.run_forecasts(r.id, 56); END LOOP;
END; $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'vexim_daily_forecasts';
    PERFORM cron.schedule('vexim_daily_forecasts', '15 3 * * *', $c$ SELECT public.run_forecasts_all(); $c$);  -- sau snapshot 03:00, trước rules 03:30
  END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_cron: %', SQLERRM;
END $$;

-- ------------------------------------------------------------
-- 5. Kế hoạch tồn kho cho 1 SKU (dùng cho bảng, rule engine và scenario planner)
--    p_lead_time / p_safety_days = NULL → lấy từ SKU / chính sách.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.inventory_plan_sku(p_sku UUID, p_lead_time INT DEFAULT NULL, p_safety_days INT DEFAULT NULL, p_use_p90 BOOLEAN DEFAULT FALSE, p_count_inbound BOOLEAN DEFAULT TRUE)
RETURNS TABLE (
  sku_id UUID, asin TEXT, title TEXT, on_hand INT, inbound INT, lead_time INT, safety_days INT, model TEXT, made_on DATE, mape NUMERIC,
  v_fc NUMERIC, demand_lead NUMERIC, days_of_cover NUMERIC, stockout_date DATE, order_by_date DATE,
  target_cover_days INT, suggested_qty INT, status TEXT, stock_value NUMERIC, overstock_days NUMERIC
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  k public.amazon_skus%ROWTYPE; pol public.policy_register%ROWTYPE; mo DATE; stock NUMERIC; cum NUMERIC := 0;
  r RECORD; lt INT; sd INT; need INT; tgt INT; q NUMERIC; dsum NUMERIC := 0; dcnt INT := 0; horizon_sum NUMERIC := 0; hmax INT := 0;
  so DATE; doc NUMERIC; vf NUMERIC; dl NUMERIC := 0; dtgt NUMERIC := 0; st TEXT; mp NUMERIC; mdl TEXT;
BEGIN
  SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  IF k.id IS NULL THEN RETURN; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = k.tenant_id;
  lt := COALESCE(p_lead_time, k.lead_time_days, pol.default_lead_time_days, 30);
  sd := COALESCE(p_safety_days, pol.safety_stock_days, 14);
  need := lt + sd; tgt := need + 28;                     -- đặt đủ cho lead time + an toàn + 1 chu kỳ đặt hàng 28 ngày
  stock := k.inventory_qty + CASE WHEN p_count_inbound THEN COALESCE(k.inventory_inbound, 0) ELSE 0 END;

  SELECT max(f.made_on) INTO mo FROM public.forecasts f WHERE f.sku_id = p_sku;
  IF mo IS NOT NULL THEN
    SELECT f.model INTO mdl FROM public.forecasts f WHERE f.sku_id = p_sku AND f.made_on = mo LIMIT 1;
    SELECT b.mape INTO mp FROM public.forecast_backtests b WHERE b.sku_id = p_sku AND b.made_on = mo AND b.chosen LIMIT 1;
    FOR r IN SELECT f.date, CASE WHEN p_use_p90 THEN f.p90 ELSE f.p50 END AS q, f.horizon
             FROM public.forecasts f WHERE f.sku_id = p_sku AND f.made_on = mo AND f.date >= CURRENT_DATE ORDER BY f.date LOOP
      hmax := hmax + 1; horizon_sum := horizon_sum + r.q;
      IF hmax <= 28 THEN dsum := dsum + r.q; dcnt := dcnt + 1; END IF;
      IF hmax <= need THEN dl := dl + r.q; END IF;
      IF hmax <= tgt THEN dtgt := dtgt + r.q; END IF;
      cum := cum + r.q;
      IF so IS NULL AND cum >= stock AND stock >= 0 THEN so := r.date; doc := hmax; END IF;
    END LOOP;
  END IF;
  vf := CASE WHEN dcnt > 0 THEN round(dsum / dcnt, 2)
             WHEN COALESCE(k.sales_last_30d, 0) > 0 THEN round(k.sales_last_30d / 30.0, 2) ELSE 0 END;
  -- ngoài horizon forecast: ngoại suy bằng mức trung bình
  IF hmax < need THEN dl := dl + vf * (need - hmax); END IF;
  IF hmax < tgt THEN dtgt := dtgt + vf * (tgt - hmax); END IF;
  IF so IS NULL AND vf > 0 THEN
    doc := round((stock - horizon_sum) / vf + hmax, 1);
    so := CURRENT_DATE + doc::int;
  END IF;
  IF vf = 0 AND so IS NULL THEN doc := NULL; END IF;
  q := GREATEST(0, ceil(dtgt - stock));

  st := CASE
    WHEN k.inventory_qty <= 0 THEN 'stockout'
    WHEN doc IS NOT NULL AND doc <= lt THEN 'order_now'          -- không kịp lead time
    WHEN doc IS NOT NULL AND doc <= need THEN 'order_soon'        -- đang ăn vào an toàn
    WHEN doc IS NOT NULL AND doc > need * 6 THEN 'overstock'
    WHEN vf = 0 THEN 'no_demand'
    ELSE 'ok' END;

  sku_id := k.id; asin := k.asin; title := k.title; on_hand := k.inventory_qty; inbound := COALESCE(k.inventory_inbound, 0);
  lead_time := lt; safety_days := sd; model := mdl; made_on := mo; mape := mp;
  v_fc := vf; demand_lead := round(dl, 0); days_of_cover := doc; stockout_date := so;
  order_by_date := CASE WHEN so IS NOT NULL THEN so - lt ELSE NULL END;
  target_cover_days := tgt; suggested_qty := CASE WHEN st IN ('stockout','order_now','order_soon') THEN q::int ELSE 0 END;
  status := st; stock_value := round(k.inventory_qty * COALESCE(k.cogs, 0), 2);
  overstock_days := CASE WHEN st = 'overstock' THEN round(doc - need * 6, 0) END;
  RETURN NEXT;
END; $$;

CREATE OR REPLACE FUNCTION public.inventory_plan(t UUID, p_lead_time INT DEFAULT NULL, p_safety_days INT DEFAULT NULL, p_use_p90 BOOLEAN DEFAULT FALSE, p_count_inbound BOOLEAN DEFAULT TRUE)
RETURNS TABLE (
  sku_id UUID, asin TEXT, title TEXT, on_hand INT, inbound INT, lead_time INT, safety_days INT, model TEXT, made_on DATE, mape NUMERIC,
  v_fc NUMERIC, demand_lead NUMERIC, days_of_cover NUMERIC, stockout_date DATE, order_by_date DATE,
  target_cover_days INT, suggested_qty INT, status TEXT, stock_value NUMERIC, overstock_days NUMERIC
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.* FROM public.amazon_skus k, LATERAL public.inventory_plan_sku(k.id, p_lead_time, p_safety_days, p_use_p90, p_count_inbound) p
  WHERE k.tenant_id = t AND k.status = 'active' AND k.tenant_id IN (SELECT public.my_tenant_ids())
  ORDER BY CASE p.status WHEN 'stockout' THEN 0 WHEN 'order_now' THEN 1 WHEN 'order_soon' THEN 2 WHEN 'overstock' THEN 3 WHEN 'no_demand' THEN 4 ELSE 5 END, p.days_of_cover NULLS LAST;
$$;
GRANT EXECUTE ON FUNCTION public.inventory_plan_sku(UUID, INT, INT, BOOLEAN, BOOLEAN), public.inventory_plan(UUID, INT, INT, BOOLEAN, BOOLEAN) TO authenticated;

-- Độ chính xác forecast (gate tuần 7‑8): MAPE mô hình được chọn so với naive7
CREATE OR REPLACE VIEW public.v_forecast_accuracy WITH (security_invoker = true) AS
WITH latest AS (SELECT sku_id, max(made_on) AS made_on FROM public.forecast_backtests GROUP BY sku_id),
b AS (SELECT fb.* FROM public.forecast_backtests fb JOIN latest l USING (sku_id, made_on))
SELECT tenant_id, model,
       count(*) AS skus,
       count(*) FILTER (WHERE chosen) AS chosen_skus,
       round(avg(mape), 1) AS avg_mape,
       round(avg(bias_pct), 1) AS avg_bias_pct
FROM b GROUP BY tenant_id, model;
GRANT SELECT ON public.v_forecast_accuracy TO authenticated;

-- ------------------------------------------------------------
-- 6. run_rules: gợi ý nhập hàng lấy số lượng từ forecast (thay công thức v × need)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.replenish_rationale(p_sku UUID)
RETURNS TABLE (qty INT, rationale TEXT) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p RECORD;
BEGIN
  SELECT * INTO p FROM public.inventory_plan_sku(p_sku);
  IF p.sku_id IS NULL THEN RETURN; END IF;
  qty := p.suggested_qty;
  rationale := format('Tồn %s đv + %s đang về; dự báo bán %s đv/ngày (mô hình %s%s). Hết hàng dự kiến %s, cần đặt trước %s (lead time %s ngày + %s ngày an toàn). Đề xuất nhập %s đv = nhu cầu %s ngày (lead time + an toàn + chu kỳ 28 ngày) − tồn hiện có.',
    p.on_hand, p.inbound, p.v_fc, COALESCE(p.model, 'catalog'), CASE WHEN p.mape IS NOT NULL THEN format(', MAPE backtest %s%%', p.mape) ELSE '' END,
    COALESCE(to_char(p.stockout_date, 'DD/MM'), '—'), COALESCE(to_char(p.order_by_date, 'DD/MM'), 'ngay'), p.lead_time, p.safety_days, p.suggested_qty, p.target_cover_days);
  RETURN NEXT;
END; $$;
GRANT EXECUTE ON FUNCTION public.replenish_rationale(UUID) TO authenticated;

-- run_rules (bản 008): STOCKOUT_IMMINENT dùng inventory_plan_sku/forecast để tính qty & rationale
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
      SELECT rr.qty, rr.rationale INTO qty, rat FROM public.replenish_rationale(k.id) rr;
      qty := COALESCE(qty, GREATEST(0, CEIL(v * need - k.inventory_qty))::int);
      msg := format('Sắp hết hàng: còn %s ngày (%s đv, bán %s đv/ngày), lead time %s ngày', m.days_of_cover, k.inventory_qty, ROUND(v,1), COALESCE(k.lead_time_days, pol.default_lead_time_days, 30));
      ctx := jsonb_build_object('doc', m.days_of_cover, 'inventory', k.inventory_qty, 'velocity', v, 'lead_time', COALESCE(k.lead_time_days, pol.default_lead_time_days, 30), 'suggested_qty', qty, 'eta', m.stockout_eta);
      IF public._open_exception(t, k.id, k.asin, 'STOCKOUT_IMMINENT', CASE WHEN m.days_of_cover < 7 THEN 'P0' ELSE 'P1' END, msg, ctx, cool) THEN
        opened := opened + 1;
        SELECT EXISTS (SELECT 1 FROM public.recommendations WHERE sku_id = k.id AND type = 'replenish' AND status IN ('draft','pending_approval','approved')) INTO rec_exists;
        IF NOT rec_exists AND qty > 0 THEN
          rat := COALESCE(rat, format('Tồn %s đv, bán %s đv/ngày → còn ~%s ngày; cần %s ngày. Đề xuất nhập %s đv.', k.inventory_qty, ROUND(v,1), m.days_of_cover, need, qty))
                 || format(' Rủi ro %s (tồn kho %s · biên %s · tốc độ %s · biến động %s; tin cậy %s%%).', risk, COALESCE(rcomp->'inventory'->>'score','n/a'), COALESCE(rcomp->'margin'->>'score','n/a'), COALESCE(rcomp->'velocity'->>'score','n/a'), COALESCE(rcomp->'volatility'->>'score','n/a'), COALESCE(ROUND(100*(rcomp->>'confidence')::numeric)::text,'?'));
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


-- ------------------------------------------------------------
-- 7. RLS
-- ------------------------------------------------------------
ALTER TABLE public.forecasts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forecast_backtests ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname='public' AND tablename IN ('forecasts','forecast_backtests')
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP;
END $$;
CREATE POLICY forecasts_select ON public.forecasts FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY fbt_select ON public.forecast_backtests FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));

-- Chạy forecast lần đầu cho mọi tenant
SELECT public.run_forecasts(id, 56) FROM public.tenants;
