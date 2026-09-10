-- ============================================================
-- 010 — Bounded automation: actions · idempotency · dry_run/canary/live · rollbacks · auto‑rollback  (Tuần 11)
-- Chạy SAU 009. Idempotent.
-- Nguyên tắc:
--   * Mọi ghi ra ngoài (write) đều đi qua bảng `actions`, gắn với recommendation đã approved. Không có đường tắt.
--   * Mặc định dry_run. canary = chỉ ASIN trong danh sách canary. live = cần bật `automation_live` trong chính sách.
--   * Idempotency key duy nhất theo (recommendation, payload) → gọi lại không tạo lệnh thứ hai.
--   * Connector hiện tại là 'internal' (ghi vào bản ghi hệ thống + audit). Khi có SP‑API credentials, Edge Function sẽ
--     nhận các action ở trạng thái 'queued' và cập nhật response – schema không đổi.
--   * Rollback: thủ công (có lý do) hoặc tự động khi metric xấu trong cửa sổ theo dõi.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Policy
-- ------------------------------------------------------------
ALTER TABLE public.policy_register
  ADD COLUMN IF NOT EXISTS automation_live       BOOLEAN NOT NULL DEFAULT FALSE,           -- công tắc tổng cho live
  ADD COLUMN IF NOT EXISTS canary_asins          TEXT[]  NOT NULL DEFAULT '{}',             -- ASIN được phép canary/live
  ADD COLUMN IF NOT EXISTS rollback_watch_hours  INTEGER NOT NULL DEFAULT 48,               -- cửa sổ theo dõi sau thực thi
  ADD COLUMN IF NOT EXISTS rollback_units_drop_pct NUMERIC(5,1) NOT NULL DEFAULT 35,        -- units/ngày giảm quá X% so với 7 ngày trước → rollback
  ADD COLUMN IF NOT EXISTS max_live_actions_per_day INTEGER NOT NULL DEFAULT 5;             -- rate limit

-- ------------------------------------------------------------
-- 2. Bảng actions & rollbacks
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.actions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  recommendation_id UUID REFERENCES public.recommendations(id) ON DELETE SET NULL,
  sku_id            UUID REFERENCES public.amazon_skus(id) ON DELETE SET NULL,
  asin              TEXT NOT NULL,
  action_type       TEXT NOT NULL CHECK (action_type IN ('price_update','inventory_note','replenish_po')),
  mode              TEXT NOT NULL CHECK (mode IN ('dry_run','canary','live')),
  connector         TEXT NOT NULL DEFAULT 'internal' CHECK (connector IN ('internal','sp_api')),
  idempotency_key   TEXT NOT NULL,
  payload           JSONB NOT NULL,           -- {asin, sku, current_price, new_price, currency, marketplace}
  response          JSONB,                    -- kết quả connector / mô phỏng
  status            TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','skipped','rolled_back')),
  attempt           INTEGER NOT NULL DEFAULT 0,
  error             TEXT,
  before_value      NUMERIC(12,2),
  after_value       NUMERIC(12,2),
  watch_until       TIMESTAMPTZ,              -- hết cửa sổ auto‑rollback
  baseline_units_per_day NUMERIC(10,2),       -- 7 ngày trước khi thực thi
  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at        TIMESTAMPTZ,
  finished_at       TIMESTAMPTZ,
  UNIQUE (tenant_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_actions_tenant ON public.actions(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_actions_watch ON public.actions(watch_until) WHERE status = 'succeeded' AND mode <> 'dry_run';

CREATE TABLE IF NOT EXISTS public.rollbacks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  action_id     UUID NOT NULL REFERENCES public.actions(id) ON DELETE CASCADE,
  trigger       TEXT NOT NULL CHECK (trigger IN ('manual','auto_metric','auto_error')),
  reason        TEXT NOT NULL,
  restored_value NUMERIC(12,2),
  metrics       JSONB,
  status        TEXT NOT NULL DEFAULT 'succeeded' CHECK (status IN ('succeeded','failed')),
  created_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rollbacks_tenant ON public.rollbacks(tenant_id, created_at DESC);

-- ------------------------------------------------------------
-- 3. Guard: không cho ghi thẳng vào actions ngoài hàm (chỉ SECURITY DEFINER functions)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actions_direct_write_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('vexim.action_ctx', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'Không ghi trực tiếp vào actions – dùng execute_recommendation()/rollback_action()';
  END IF;
  RETURN COALESCE(NEW, OLD);
END; $$;
DROP TRIGGER IF EXISTS trg_actions_guard ON public.actions;
CREATE TRIGGER trg_actions_guard BEFORE INSERT OR UPDATE OR DELETE ON public.actions FOR EACH ROW EXECUTE FUNCTION public.actions_direct_write_guard();
DROP TRIGGER IF EXISTS trg_rollbacks_guard ON public.rollbacks;
CREATE TRIGGER trg_rollbacks_guard BEFORE INSERT OR UPDATE OR DELETE ON public.rollbacks FOR EACH ROW EXECUTE FUNCTION public.actions_direct_write_guard();

-- ------------------------------------------------------------
-- 4. Connector nội bộ (mô phỏng SP‑API Listings Items PATCH price)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._connector_internal(a public.actions)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE k public.amazon_skus%ROWTYPE; newp NUMERIC;
BEGIN
  SELECT * INTO k FROM public.amazon_skus WHERE id = a.sku_id;
  IF k.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'SKU không tồn tại'); END IF;
  IF a.action_type = 'price_update' THEN
    newp := (a.payload->>'new_price')::numeric;
    IF newp IS NULL OR newp <= 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'Giá mới không hợp lệ'); END IF;
    IF a.mode = 'dry_run' THEN
      RETURN jsonb_build_object('ok', true, 'simulated', true, 'connector', 'internal',
        'sp_api_request', jsonb_build_object('method', 'PATCH', 'path', format('/listings/2021-08-01/items/{sellerId}/%s', coalesce(k.sku, k.asin)),
          'body', jsonb_build_object('productType', 'PRODUCT', 'patches', jsonb_build_array(jsonb_build_object('op', 'replace', 'path', '/attributes/purchasable_offer',
            'value', jsonb_build_array(jsonb_build_object('marketplace_id', k.marketplace, 'currency', 'USD', 'our_price', jsonb_build_array(jsonb_build_object('schedule', jsonb_build_array(jsonb_build_object('value_with_tax', newp)))))))))),
        'would_change', jsonb_build_object('from', k.current_price, 'to', newp));
    END IF;
    PERFORM set_config('vexim.action_ctx', 'on', true);
    UPDATE public.amazon_skus SET current_price = newp, last_ingested_at = now() WHERE id = k.id;
    RETURN jsonb_build_object('ok', true, 'simulated', false, 'connector', 'internal', 'applied', jsonb_build_object('from', k.current_price, 'to', newp), 'submission_id', gen_random_uuid());
  ELSIF a.action_type = 'replenish_po' THEN
    IF a.mode = 'dry_run' THEN RETURN jsonb_build_object('ok', true, 'simulated', true, 'po', a.payload); END IF;
    UPDATE public.amazon_skus SET inventory_inbound = COALESCE(inventory_inbound, 0) + (a.payload->>'qty')::int WHERE id = k.id;
    RETURN jsonb_build_object('ok', true, 'simulated', false, 'inbound_added', (a.payload->>'qty')::int);
  END IF;
  RETURN jsonb_build_object('ok', true, 'simulated', a.mode = 'dry_run', 'note', 'ghi chú nội bộ');
END; $$;

-- ------------------------------------------------------------
-- 5. execute_recommendation(rec, mode) → actions row
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_recommendation(p_rec UUID, p_mode TEXT DEFAULT 'dry_run')
RETURNS public.actions LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.recommendations%ROWTYPE; k public.amazon_skus%ROWTYPE; pol public.policy_register%ROWTYPE; a public.actions;
        atype TEXT; payload JSONB; key TEXT; resp JSONB; live_today INT; base NUMERIC; dry_ok BOOLEAN; chg NUMERIC;
BEGIN
  IF p_mode NOT IN ('dry_run','canary','live') THEN RAISE EXCEPTION 'mode không hợp lệ'; END IF;
  SELECT * INTO r FROM public.recommendations WHERE id = p_rec;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy gợi ý'; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = r.tenant_id;
  SELECT * INTO k FROM public.amazon_skus WHERE id = r.sku_id;

  -- quyền: dry_run = operator+; canary/live = theo cấp duyệt của gợi ý
  IF auth.uid() IS NOT NULL THEN
    IF NOT public.has_role(r.tenant_id, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
    IF p_mode <> 'dry_run' AND NOT public.can_approve(r.tenant_id, r.required_approval_level) THEN RAISE EXCEPTION 'Cấp % cần quyền cao hơn để thực thi', r.required_approval_level; END IF;
  END IF;

  -- điều kiện chạy thật
  IF p_mode <> 'dry_run' THEN
    IF r.status <> 'approved' THEN RAISE EXCEPTION 'Chỉ thực thi gợi ý đã được duyệt (hiện: %)', r.status; END IF;
    IF p_mode = 'live' AND NOT pol.automation_live THEN RAISE EXCEPTION 'Chế độ live đang tắt trong Chính sách'; END IF;
    IF NOT (r.asin = ANY(pol.canary_asins)) THEN RAISE EXCEPTION 'ASIN % chưa nằm trong danh sách canary', r.asin; END IF;
    SELECT count(*) INTO live_today FROM public.actions WHERE tenant_id = r.tenant_id AND mode <> 'dry_run' AND created_at > now() - interval '24 hours' AND status IN ('succeeded','running','queued');
    IF live_today >= pol.max_live_actions_per_day THEN RAISE EXCEPTION 'Đã đạt giới hạn % lệnh/ngày', pol.max_live_actions_per_day; END IF;
    SELECT EXISTS (SELECT 1 FROM public.actions WHERE recommendation_id = r.id AND mode = 'dry_run' AND status = 'succeeded') INTO dry_ok;
    IF NOT dry_ok THEN RAISE EXCEPTION 'Cần chạy thử (dry‑run) thành công trước'; END IF;
  END IF;

  -- payload theo loại gợi ý
  CASE r.type
    WHEN 'price_adjust' THEN
      atype := 'price_update';
      IF r.proposed_value IS NULL OR k.id IS NULL THEN RAISE EXCEPTION 'Gợi ý thiếu giá đề xuất / SKU'; END IF;
      chg := abs(r.proposed_value / NULLIF(k.current_price, 0) - 1) * 100;
      IF chg > pol.price_change_max_pct THEN RAISE EXCEPTION 'Thay đổi giá % phần trăm vượt trần % phần trăm của chính sách', round(chg, 1), pol.price_change_max_pct; END IF;
      IF (r.proposed_value - k.cogs - k.fee_per_unit - r.proposed_value * k.referral_fee_pct / 100) / r.proposed_value * 100 < pol.min_margin_pct THEN
        RAISE EXCEPTION 'Giá mới làm biên dưới mức tối thiểu % phần trăm', pol.min_margin_pct; END IF;
      payload := jsonb_build_object('asin', r.asin, 'sku', k.sku, 'marketplace', k.marketplace, 'current_price', k.current_price, 'new_price', r.proposed_value, 'currency', 'USD');
    WHEN 'replenish' THEN
      atype := 'replenish_po';
      payload := jsonb_build_object('asin', r.asin, 'sku', k.sku, 'qty', r.proposed_value::int, 'supplier', k.supplier, 'lead_time_days', k.lead_time_days);
    ELSE
      atype := 'inventory_note';
      payload := jsonb_build_object('asin', r.asin, 'note', r.title);
  END CASE;
  key := md5(r.id::text || ':' || p_mode || ':' || payload::text);

  PERFORM set_config('vexim.action_ctx', 'on', true);
  -- idempotent: đã có lệnh thành công/đang chạy cùng key → trả lại
  SELECT * INTO a FROM public.actions WHERE tenant_id = r.tenant_id AND idempotency_key = key;
  IF a.id IS NOT NULL AND a.status IN ('succeeded','running','queued') THEN RETURN a; END IF;
  IF a.id IS NOT NULL THEN
    UPDATE public.actions SET status = 'running', attempt = attempt + 1, started_at = now(), error = NULL WHERE id = a.id RETURNING * INTO a;
  ELSE
    INSERT INTO public.actions (tenant_id, recommendation_id, sku_id, asin, action_type, mode, idempotency_key, payload, status, attempt, before_value, started_at, created_by)
    VALUES (r.tenant_id, r.id, r.sku_id, r.asin, atype, p_mode, key, payload, 'running', 1, CASE WHEN atype = 'price_update' THEN k.current_price END, now(), auth.uid())
    RETURNING * INTO a;
  END IF;

  BEGIN
    resp := public._connector_internal(a);
  EXCEPTION WHEN OTHERS THEN
    resp := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  IF (resp->>'ok')::boolean THEN
    SELECT COALESCE(AVG(units), 0) INTO base FROM public.sku_daily_snapshots WHERE sku_id = r.sku_id AND date > CURRENT_DATE - 7 AND date <= CURRENT_DATE AND units IS NOT NULL;
    UPDATE public.actions SET status = 'succeeded', response = resp, finished_at = now(),
      after_value = CASE WHEN atype = 'price_update' THEN (payload->>'new_price')::numeric END,
      watch_until = CASE WHEN p_mode <> 'dry_run' THEN now() + make_interval(hours => pol.rollback_watch_hours) END,
      baseline_units_per_day = CASE WHEN p_mode <> 'dry_run' THEN base END
    WHERE id = a.id RETURNING * INTO a;
    IF p_mode <> 'dry_run' THEN
      UPDATE public.recommendations SET status = 'executed' WHERE id = r.id AND status = 'approved';
    END IF;
  ELSE
    UPDATE public.actions SET status = 'failed', response = resp, error = resp->>'error', finished_at = now() WHERE id = a.id RETURNING * INTO a;
  END IF;
  RETURN a;
END; $$;
GRANT EXECUTE ON FUNCTION public.execute_recommendation(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 6. rollback_action(action, reason, trigger)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rollback_action(p_action UUID, p_reason TEXT, p_trigger TEXT DEFAULT 'manual', p_metrics JSONB DEFAULT NULL)
RETURNS public.rollbacks LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.actions%ROWTYPE; rb public.rollbacks; r public.recommendations%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public.actions WHERE id = p_action;
  IF a.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy lệnh'; END IF;
  IF a.status <> 'succeeded' OR a.mode = 'dry_run' THEN RAISE EXCEPTION 'Chỉ hoàn tác lệnh đã thực thi thật'; END IF;
  IF coalesce(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'Hoàn tác phải có lý do'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_role(a.tenant_id, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;

  PERFORM set_config('vexim.action_ctx', 'on', true);
  IF a.action_type = 'price_update' AND a.before_value IS NOT NULL THEN
    UPDATE public.amazon_skus SET current_price = a.before_value, last_ingested_at = now() WHERE id = a.sku_id;
  ELSIF a.action_type = 'replenish_po' THEN
    UPDATE public.amazon_skus SET inventory_inbound = GREATEST(0, COALESCE(inventory_inbound, 0) - (a.payload->>'qty')::int) WHERE id = a.sku_id;
  END IF;
  UPDATE public.actions SET status = 'rolled_back', watch_until = NULL WHERE id = a.id;
  INSERT INTO public.rollbacks (tenant_id, action_id, trigger, reason, restored_value, metrics, created_by)
  VALUES (a.tenant_id, a.id, p_trigger, p_reason, a.before_value, p_metrics, auth.uid()) RETURNING * INTO rb;

  SELECT * INTO r FROM public.recommendations WHERE id = a.recommendation_id;
  IF r.id IS NOT NULL AND r.status = 'executed' THEN
    UPDATE public.recommendations SET status = 'rolled_back', rollback_reason = format('[%s] %s', p_trigger, p_reason) WHERE id = r.id;
  END IF;
  RETURN rb;
END; $$;
GRANT EXECUTE ON FUNCTION public.rollback_action(UUID, TEXT, TEXT, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 7. Auto‑rollback: units/ngày trong cửa sổ theo dõi giảm > X% so với baseline (cần ≥ 2 ngày dữ liệu)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_auto_rollbacks(t UUID DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; pol public.policy_register%ROWTYPE; cur NUMERIC; days INT; n INT := 0; drop_pct NUMERIC;
BEGIN
  FOR a IN SELECT * FROM public.actions WHERE status = 'succeeded' AND mode <> 'dry_run' AND action_type = 'price_update'
           AND (t IS NULL OR tenant_id = t) AND watch_until IS NOT NULL AND baseline_units_per_day > 0 LOOP
    SELECT * INTO pol FROM public.policy_register WHERE tenant_id = a.tenant_id;
    IF now() > a.watch_until THEN
      PERFORM set_config('vexim.action_ctx', 'on', true);
      UPDATE public.actions SET watch_until = NULL WHERE id = a.id;   -- hết cửa sổ, giữ nguyên
      CONTINUE;
    END IF;
    SELECT AVG(units), COUNT(*) INTO cur, days FROM public.sku_daily_snapshots
     WHERE sku_id = a.sku_id AND date > a.finished_at::date AND units IS NOT NULL;
    CONTINUE WHEN days < 2 OR cur IS NULL;
    drop_pct := (1 - cur / a.baseline_units_per_day) * 100;
    IF drop_pct >= pol.rollback_units_drop_pct THEN
      PERFORM public.rollback_action(a.id, format('Units/ngày giảm %s%% (%s → %s) trong %s ngày sau khi đổi giá', round(drop_pct), round(a.baseline_units_per_day, 1), round(cur, 1), days),
        'auto_metric', jsonb_build_object('baseline', a.baseline_units_per_day, 'current', cur, 'days', days, 'drop_pct', round(drop_pct, 1)));
      PERFORM public._open_exception(a.tenant_id, a.sku_id, a.asin, 'AUTO_ROLLBACK', 'P1',
        format('Đã tự hoàn tác giá %s → %s: units giảm %s%% sau khi đổi giá', a.after_value, a.before_value, round(drop_pct)),
        jsonb_build_object('action_id', a.id, 'drop_pct', round(drop_pct, 1)), COALESCE(pol.cooldown_days, 7));
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.check_auto_rollbacks(UUID) TO authenticated;

-- gắn vào cron 03:30 cùng rules
CREATE OR REPLACE FUNCTION public.run_rules_all()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.tenants LOOP
    PERFORM public.run_rules(r.id, 'cron');
    PERFORM public.run_review_rules(r.id);
    PERFORM public.check_auto_rollbacks(r.id);
  END LOOP;
END; $$;

-- ------------------------------------------------------------
-- 8. Gate: uncontrolled writes & thống kê automation
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_automation_stats WITH (security_invoker = true) AS
SELECT a.tenant_id,
       count(*) FILTER (WHERE a.mode = 'dry_run') AS dry_runs,
       count(*) FILTER (WHERE a.mode = 'canary' AND a.status IN ('succeeded','rolled_back')) AS canary_runs,
       count(*) FILTER (WHERE a.mode = 'live' AND a.status IN ('succeeded','rolled_back')) AS live_runs,
       count(*) FILTER (WHERE a.status = 'failed') AS failed,
       count(*) FILTER (WHERE a.status = 'rolled_back') AS rolled_back,
       count(*) FILTER (WHERE a.mode <> 'dry_run' AND a.status IN ('succeeded','rolled_back')
                        AND (a.recommendation_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.recommendations r WHERE r.id = a.recommendation_id AND r.approved_at IS NOT NULL))) AS uncontrolled_writes,
       count(*) FILTER (WHERE a.mode <> 'dry_run' AND a.created_at > now() - interval '24 hours' AND a.status IN ('succeeded','running','queued')) AS live_last_24h,
       max(a.finished_at) FILTER (WHERE a.mode <> 'dry_run') AS last_live_at
FROM public.actions a GROUP BY a.tenant_id;
GRANT SELECT ON public.v_automation_stats TO authenticated;

-- ------------------------------------------------------------
-- 9. RLS (chỉ SELECT; ghi qua hàm)
-- ------------------------------------------------------------
ALTER TABLE public.actions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rollbacks ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname='public' AND tablename IN ('actions','rollbacks')
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP;
END $$;
CREATE POLICY actions_select   ON public.actions   FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY rollbacks_select ON public.rollbacks FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));

-- audit
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'write_audit_log') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_audit_actions ON public.actions';
    EXECUTE 'CREATE TRIGGER trg_audit_actions AFTER INSERT OR UPDATE ON public.actions FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_audit_rollbacks ON public.rollbacks';
    EXECUTE 'CREATE TRIGGER trg_audit_rollbacks AFTER INSERT ON public.rollbacks FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()';
  END IF;
END $$;
