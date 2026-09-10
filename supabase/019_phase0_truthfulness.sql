-- ============================================================
-- 019 — PHASE 0: Truthfulness & safety
-- Chạy SAU 018. Idempotent.
--   1. actions.execution_channel + amazon_applied: nói thật hành động đi đâu
--      (internal_record | manual_seller_central | sp_api). Không còn submission_id giả.
--      `status = succeeded` = thành công TRÊN CHANNEL đó; amazon_applied chỉ true khi sp_api xác nhận.
--   2. Khoá mode live khi tenant chưa có data_source sp_api status=connected.
--   3. publish_records + policy publish_evidence_required: content không được
--      chuyển 'published' nếu thiếu bằng chứng.
--   4. v_system_health: trạng thái pg_cron/job (ok | missing | unknown), không giả định.
--   5. Không đổi approval_tier / automation_level; không thêm write‑action.
-- ============================================================

-- ------------------------------------------------------------
-- 1. actions.execution_channel / amazon_applied
-- ------------------------------------------------------------
ALTER TABLE public.actions
  ADD COLUMN IF NOT EXISTS execution_channel TEXT NOT NULL DEFAULT 'internal_record'
    CHECK (execution_channel IN ('internal_record','manual_seller_central','sp_api')),
  ADD COLUMN IF NOT EXISTS amazon_applied BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS manual_confirmed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS manual_confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS manual_evidence TEXT;
COMMENT ON COLUMN public.actions.execution_channel IS 'internal_record: chỉ ghi DB nội bộ (chưa tác động Amazon). manual_seller_central: người thực hiện tay trên Seller Central và xác nhận. sp_api: gửi qua API (P7).';
COMMENT ON COLUMN public.actions.amazon_applied IS 'true CHỈ khi thay đổi đã được xác nhận trên Amazon (manual confirm hoặc sp_api verify). status=succeeded KHÔNG hàm ý điều này.';
COMMENT ON COLUMN public.actions.connector IS 'DEPRECATED (019): dùng execution_channel.';

-- Backfill: mọi action hiện có đều là ghi nhận nội bộ; xoá submission_id giả khỏi response
DO $$
BEGIN
  PERFORM set_config('vexim.action_ctx', 'on', true);
  UPDATE public.actions SET execution_channel = 'internal_record', amazon_applied = false
   WHERE connector = 'internal' AND execution_channel = 'internal_record' AND amazon_applied = false;
  UPDATE public.actions SET response = (response - 'submission_id') || jsonb_build_object('note', 'Ghi nhận nội bộ — chưa tác động Amazon (backfill 019)')
   WHERE response ? 'submission_id';
END $$;

-- Connector nội bộ: không sinh submission_id, đánh dấu rõ là nội bộ
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
      RETURN jsonb_build_object('ok', true, 'simulated', true, 'channel', 'internal_record',
        'sp_api_request_preview', jsonb_build_object('method', 'PATCH', 'path', format('/listings/2021-08-01/items/{sellerId}/%s', coalesce(k.sku, k.asin)),
          'body', jsonb_build_object('productType', 'PRODUCT', 'patches', jsonb_build_array(jsonb_build_object('op', 'replace', 'path', '/attributes/purchasable_offer',
            'value', jsonb_build_array(jsonb_build_object('marketplace_id', k.marketplace, 'currency', 'USD', 'our_price', jsonb_build_array(jsonb_build_object('schedule', jsonb_build_array(jsonb_build_object('value_with_tax', newp)))))))))),
        'would_change', jsonb_build_object('from', k.current_price, 'to', newp));
    END IF;
    PERFORM set_config('vexim.action_ctx', 'on', true);
    UPDATE public.amazon_skus SET current_price = newp, last_ingested_at = now() WHERE id = k.id;
    RETURN jsonb_build_object('ok', true, 'simulated', false, 'channel', 'internal_record', 'amazon_applied', false,
      'applied_internal', jsonb_build_object('from', k.current_price, 'to', newp),
      'note', 'Đã cập nhật giá trong hệ thống nội bộ. CHƯA tác động Amazon — cần thực hiện tay trên Seller Central rồi xác nhận.');
  ELSIF a.action_type = 'replenish_po' THEN
    IF a.mode = 'dry_run' THEN RETURN jsonb_build_object('ok', true, 'simulated', true, 'channel', 'internal_record', 'po', a.payload); END IF;
    UPDATE public.amazon_skus SET inventory_inbound = COALESCE(inventory_inbound, 0) + (a.payload->>'qty')::int WHERE id = k.id;
    RETURN jsonb_build_object('ok', true, 'simulated', false, 'channel', 'internal_record', 'amazon_applied', false,
      'inbound_added_internal', (a.payload->>'qty')::int, 'note', 'Chỉ ghi nhận inbound nội bộ. Không phát hành PO.');
  ELSE
    RETURN jsonb_build_object('ok', true, 'simulated', a.mode = 'dry_run', 'channel', 'internal_record', 'amazon_applied', false, 'note', 'Ghi chú nội bộ');
  END IF;
END; $$;

-- Kiểm tra tenant có kênh sp_api đã kết nối chưa (P2 sẽ set status=connected)
CREATE OR REPLACE FUNCTION public.tenant_has_sp_api(t UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.data_sources WHERE tenant_id = t AND kind = 'sp_api' AND enabled AND status = 'connected');
$$;
GRANT EXECUTE ON FUNCTION public.tenant_has_sp_api(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 2. execute_recommendation v3: khoá live khi chưa có sp_api; ghi execution_channel
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_recommendation(p_rec UUID, p_mode TEXT DEFAULT 'dry_run')
RETURNS public.actions LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.recommendations%ROWTYPE; k public.amazon_skus%ROWTYPE; pol public.policy_register%ROWTYPE; a public.actions;
        atype TEXT; v_payload JSONB; key TEXT; resp JSONB; live_today INT; base NUMERIC; dry_ok BOOLEAN; chg NUMERIC; chan TEXT;
BEGIN
  IF p_mode NOT IN ('dry_run','canary','live') THEN RAISE EXCEPTION 'mode không hợp lệ'; END IF;
  SELECT * INTO r FROM public.recommendations WHERE id = p_rec;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy gợi ý'; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = r.tenant_id;
  SELECT * INTO k FROM public.amazon_skus WHERE id = r.sku_id;

  IF auth.uid() IS NOT NULL THEN
    IF p_mode = 'dry_run' THEN
      IF NOT public.has_permission(r.tenant_id, 'action.dry_run') THEN RAISE EXCEPTION 'Không đủ quyền chạy thử'; END IF;
    ELSE
      IF NOT public.has_permission(r.tenant_id, 'action.execute') THEN RAISE EXCEPTION 'Không đủ quyền thực thi'; END IF;
      IF NOT public.can_approve(r.tenant_id, r.approval_tier) THEN RAISE EXCEPTION 'Cấp duyệt % cần quyền cao hơn để thực thi', r.approval_tier; END IF;
    END IF;
  END IF;
  IF p_mode = 'live' AND pol.max_automation_level <> 'L4' THEN
    RAISE EXCEPTION 'Chính sách giới hạn mức tự động hoá ở % — chế độ live (L4) chưa được bật', pol.max_automation_level;
  END IF;
  -- PHASE 0: live (tác động Amazon thật) chỉ khi tenant có kênh sp_api đã kết nối
  IF p_mode = 'live' AND NOT public.tenant_has_sp_api(r.tenant_id) THEN
    RAISE EXCEPTION 'Chưa có kết nối SP‑API cho tenant — không thể chạy live. Dùng canary (ghi nhận nội bộ) rồi thực hiện tay trên Seller Central.';
  END IF;
  chan := CASE WHEN p_mode = 'live' THEN 'sp_api' ELSE 'internal_record' END;

  IF p_mode <> 'dry_run' THEN
    IF r.status <> 'approved' THEN RAISE EXCEPTION 'Chỉ thực thi gợi ý đã được duyệt (hiện: %)', r.status; END IF;
    IF p_mode = 'live' AND NOT pol.automation_live THEN RAISE EXCEPTION 'Chế độ live đang tắt trong Chính sách'; END IF;
    IF NOT (r.asin = ANY(pol.canary_asins)) THEN RAISE EXCEPTION 'ASIN % chưa nằm trong danh sách canary', r.asin; END IF;
    SELECT count(*) INTO live_today FROM public.actions WHERE tenant_id = r.tenant_id AND mode <> 'dry_run' AND created_at > now() - interval '24 hours' AND status IN ('succeeded','running','queued');
    IF live_today >= pol.max_live_actions_per_day THEN RAISE EXCEPTION 'Đã đạt giới hạn % lệnh/ngày', pol.max_live_actions_per_day; END IF;
    SELECT EXISTS (SELECT 1 FROM public.actions WHERE recommendation_id = r.id AND mode = 'dry_run' AND status = 'succeeded') INTO dry_ok;
    IF NOT dry_ok THEN RAISE EXCEPTION 'Cần chạy thử (dry‑run) thành công trước'; END IF;
  END IF;

  CASE r.type
    WHEN 'price_adjust' THEN
      atype := 'price_update';
      IF r.proposed_value IS NULL OR k.id IS NULL THEN RAISE EXCEPTION 'Gợi ý thiếu giá đề xuất / SKU'; END IF;
      chg := abs(r.proposed_value / NULLIF(k.current_price, 0) - 1) * 100;
      IF chg > pol.price_change_max_pct THEN RAISE EXCEPTION 'Thay đổi giá % phần trăm vượt trần % phần trăm của chính sách', round(chg, 1), pol.price_change_max_pct; END IF;
      IF (r.proposed_value - k.cogs - k.fee_per_unit - r.proposed_value * k.referral_fee_pct / 100) / r.proposed_value * 100 < pol.min_margin_pct THEN
        RAISE EXCEPTION 'Giá mới làm biên dưới mức tối thiểu % phần trăm', pol.min_margin_pct; END IF;
      v_payload := jsonb_build_object('asin', r.asin, 'sku', k.sku, 'marketplace', k.marketplace, 'current_price', k.current_price, 'new_price', r.proposed_value, 'currency', 'USD');
    WHEN 'replenish' THEN
      atype := 'replenish_po';
      v_payload := jsonb_build_object('asin', r.asin, 'sku', k.sku, 'qty', r.proposed_value::int, 'supplier', k.supplier, 'lead_time_days', k.lead_time_days);
    ELSE
      atype := 'inventory_note';
      v_payload := jsonb_build_object('asin', r.asin, 'note', r.title);
  END CASE;
  key := md5(r.id::text || ':' || p_mode || ':' || v_payload::text);

  PERFORM set_config('vexim.action_ctx', 'on', true);
  SELECT * INTO a FROM public.actions WHERE tenant_id = r.tenant_id AND idempotency_key = key;
  IF a.id IS NOT NULL AND a.status IN ('succeeded','running','queued') THEN RETURN a; END IF;
  IF a.id IS NOT NULL THEN
    UPDATE public.actions SET status = 'running', attempt = attempt + 1, started_at = now(), error = NULL WHERE id = a.id RETURNING * INTO a;
  ELSE
    INSERT INTO public.actions (tenant_id, recommendation_id, sku_id, asin, action_type, mode, idempotency_key, payload, status, attempt, before_value, started_at, created_by, automation_level, execution_channel, amazon_applied)
    VALUES (r.tenant_id, r.id, r.sku_id, r.asin, atype, p_mode, key, v_payload, 'running', 1, CASE WHEN atype = 'price_update' THEN k.current_price END, now(), auth.uid(),
            CASE WHEN p_mode = 'live' THEN 'L4' ELSE 'L3' END, chan, false)
    RETURNING * INTO a;
  END IF;

  -- Phase 0: chỉ có connector nội bộ. Nhánh sp_api sẽ do worker (P7) đảm nhiệm — hiện không thể tới đây vì đã chặn ở trên.
  BEGIN
    IF chan = 'sp_api' THEN
      resp := jsonb_build_object('ok', false, 'error', 'Kênh sp_api chưa được triển khai');
    ELSE
      resp := public._connector_internal(a);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    resp := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  IF (resp->>'ok')::boolean THEN
    SELECT COALESCE(AVG(units), 0) INTO base FROM public.sku_daily_snapshots WHERE sku_id = r.sku_id AND date > CURRENT_DATE - 7 AND date <= CURRENT_DATE AND units IS NOT NULL;
    UPDATE public.actions SET status = 'succeeded', response = resp, finished_at = now(),
      after_value = CASE WHEN atype = 'price_update' THEN (v_payload->>'new_price')::numeric END,
      watch_until = CASE WHEN p_mode <> 'dry_run' THEN now() + make_interval(hours => pol.rollback_watch_hours) END,
      baseline_units_per_day = CASE WHEN p_mode <> 'dry_run' THEN base END,
      amazon_applied = false
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

-- Người thực hiện tay trên Seller Central xác nhận: chuyển channel → manual_seller_central, amazon_applied=true (cần bằng chứng)
CREATE OR REPLACE FUNCTION public.confirm_manual_execution(p_action UUID, p_evidence TEXT)
RETURNS public.actions LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.actions;
BEGIN
  SELECT * INTO a FROM public.actions WHERE id = p_action;
  IF a.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy lệnh'; END IF;
  IF a.mode = 'dry_run' OR a.status <> 'succeeded' THEN RAISE EXCEPTION 'Chỉ xác nhận lệnh canary đã ghi nhận nội bộ'; END IF;
  IF a.execution_channel <> 'internal_record' THEN RAISE EXCEPTION 'Lệnh đã ở kênh %', a.execution_channel; END IF;
  IF length(coalesce(trim(p_evidence), '')) < 5 THEN RAISE EXCEPTION 'Cần bằng chứng (URL/ghi chú ≥ 5 ký tự) đã thực hiện trên Seller Central'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(a.tenant_id, 'action.execute') THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
  PERFORM set_config('vexim.action_ctx', 'on', true);
  UPDATE public.actions SET execution_channel = 'manual_seller_central', amazon_applied = true,
    manual_confirmed_by = auth.uid(), manual_confirmed_at = now(), manual_evidence = trim(p_evidence)
  WHERE id = a.id RETURNING * INTO a;
  RETURN a;
END; $$;
GRANT EXECUTE ON FUNCTION public.confirm_manual_execution(UUID, TEXT) TO authenticated;

-- v_automation_stats: tách rõ nội bộ / đã áp dụng trên Amazon
DROP VIEW IF EXISTS public.v_automation_stats;
CREATE VIEW public.v_automation_stats WITH (security_invoker = true) AS
SELECT a.tenant_id,
       count(*) FILTER (WHERE a.mode = 'dry_run') AS dry_runs,
       count(*) FILTER (WHERE a.mode = 'canary' AND a.status IN ('succeeded','rolled_back')) AS canary_runs,
       count(*) FILTER (WHERE a.mode = 'live' AND a.status IN ('succeeded','rolled_back')) AS live_runs,
       count(*) FILTER (WHERE a.mode <> 'dry_run' AND a.status IN ('succeeded','rolled_back') AND a.execution_channel = 'internal_record') AS internal_records,
       count(*) FILTER (WHERE a.amazon_applied) AS amazon_applied,
       count(*) FILTER (WHERE a.status = 'failed') AS failed,
       count(*) FILTER (WHERE a.status = 'rolled_back') AS rolled_back,
       count(*) FILTER (WHERE a.mode <> 'dry_run' AND a.status IN ('succeeded','rolled_back')
                        AND (a.recommendation_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.recommendations r WHERE r.id = a.recommendation_id AND r.approved_at IS NOT NULL))) AS uncontrolled_writes,
       count(*) FILTER (WHERE a.mode <> 'dry_run' AND a.created_at > now() - interval '24 hours' AND a.status IN ('succeeded','running','queued')) AS live_last_24h,
       max(a.finished_at) FILTER (WHERE a.mode <> 'dry_run') AS last_live_at
FROM public.actions a GROUP BY a.tenant_id;
GRANT SELECT ON public.v_automation_stats TO authenticated;

-- ------------------------------------------------------------
-- 3. publish_records + bằng chứng publish
-- ------------------------------------------------------------
ALTER TABLE public.policy_register ADD COLUMN IF NOT EXISTS publish_evidence_required BOOLEAN NOT NULL DEFAULT true;
COMMENT ON COLUMN public.policy_register.publish_evidence_required IS 'true: content chỉ chuyển published khi có publish_records kèm bằng chứng (URL hoặc ghi chú).';

CREATE TABLE IF NOT EXISTS public.publish_records (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  content_version_id UUID NOT NULL REFERENCES public.content_versions(id) ON DELETE CASCADE,
  sku_id             UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  asin               TEXT NOT NULL,
  marketplace        TEXT NOT NULL,
  kind               TEXT NOT NULL CHECK (kind IN ('publish','rollback')),
  channel            TEXT NOT NULL CHECK (channel IN ('manual','api')),
  performed_by       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  performed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  evidence_url       TEXT,
  evidence_note      TEXT,
  evidence_ref       TEXT,                                   -- đường dẫn storage ảnh chụp (tuỳ chọn)
  verify_status      TEXT NOT NULL DEFAULT 'not_verified' CHECK (verify_status IN ('not_verified','manual_verified','api_verified','failed')),
  verified_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  verified_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (evidence_url IS NULL OR evidence_url ~* '^https?://'),
  CHECK (coalesce(length(trim(evidence_url)),0) > 0 OR coalesce(length(trim(evidence_note)),0) >= 5 OR evidence_ref IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_publish_records_version ON public.publish_records(content_version_id, performed_at DESC);
ALTER TABLE public.publish_records ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pubrec_select ON public.publish_records;
CREATE POLICY pubrec_select ON public.publish_records FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
-- ghi chỉ qua RPC (không policy insert/update/delete)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'write_audit_log') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_audit_publish_records ON public.publish_records';
    EXECUTE 'CREATE TRIGGER trg_audit_publish_records AFTER INSERT OR UPDATE ON public.publish_records FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()';
  END IF;
END $$;

-- RPC: ghi nhận đã publish (kèm bằng chứng) và chuyển version sang published trong 1 giao dịch
CREATE OR REPLACE FUNCTION public.record_publish(p_version UUID, p_evidence_url TEXT DEFAULT NULL, p_evidence_note TEXT DEFAULT NULL, p_marketplace TEXT DEFAULT NULL, p_evidence_ref TEXT DEFAULT NULL)
RETURNS public.publish_records LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.content_versions%ROWTYPE; k public.amazon_skus%ROWTYPE; pr public.publish_records;
BEGIN
  SELECT * INTO v FROM public.content_versions WHERE id = p_version;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy version'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(v.tenant_id, 'content.publish') THEN RAISE EXCEPTION 'Không đủ quyền ghi nhận publish (content.publish)'; END IF;
  IF v.status <> 'approved' THEN RAISE EXCEPTION 'Chỉ ghi nhận publish cho bản đã approved (hiện: %)', v.status; END IF;
  SELECT * INTO k FROM public.amazon_skus WHERE id = v.sku_id;
  IF coalesce(length(trim(p_evidence_url)),0) = 0 AND coalesce(length(trim(p_evidence_note)),0) < 5 AND p_evidence_ref IS NULL THEN
    RAISE EXCEPTION 'Cần bằng chứng publish: URL listing hoặc ghi chú (≥ 5 ký tự) hoặc ảnh chụp';
  END IF;
  INSERT INTO public.publish_records (tenant_id, content_version_id, sku_id, asin, marketplace, kind, channel, performed_by, evidence_url, evidence_note, evidence_ref, verify_status, verified_by, verified_at)
  VALUES (v.tenant_id, v.id, v.sku_id, k.asin, COALESCE(p_marketplace, k.marketplace), 'publish', 'manual', auth.uid(), NULLIF(trim(p_evidence_url),''), NULLIF(trim(p_evidence_note),''), p_evidence_ref,
          'manual_verified', auth.uid(), now())
  RETURNING * INTO pr;
  PERFORM set_config('vexim.publish_ctx', pr.id::text, true);
  UPDATE public.content_versions SET status = 'published', publish_channel = 'seller_central_manual' WHERE id = v.id;
  RETURN pr;
END; $$;
GRANT EXECUTE ON FUNCTION public.record_publish(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- RPC: rollback kèm ghi nhận (đã khôi phục trên Seller Central)
CREATE OR REPLACE FUNCTION public.record_rollback(p_version UUID, p_reason TEXT, p_evidence_url TEXT DEFAULT NULL, p_evidence_note TEXT DEFAULT NULL)
RETURNS public.publish_records LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.content_versions%ROWTYPE; k public.amazon_skus%ROWTYPE; pr public.publish_records;
BEGIN
  SELECT * INTO v FROM public.content_versions WHERE id = p_version;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy version'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(v.tenant_id, 'content.publish') THEN RAISE EXCEPTION 'Không đủ quyền rollback'; END IF;
  IF v.status <> 'published' THEN RAISE EXCEPTION 'Chỉ rollback bản published'; END IF;
  IF coalesce(length(trim(p_reason)),0) = 0 THEN RAISE EXCEPTION 'Rollback phải có lý do'; END IF;
  SELECT * INTO k FROM public.amazon_skus WHERE id = v.sku_id;
  INSERT INTO public.publish_records (tenant_id, content_version_id, sku_id, asin, marketplace, kind, channel, performed_by, evidence_url, evidence_note, verify_status, verified_by, verified_at)
  VALUES (v.tenant_id, v.id, v.sku_id, k.asin, k.marketplace, 'rollback', 'manual', auth.uid(), NULLIF(trim(p_evidence_url),''), COALESCE(NULLIF(trim(p_evidence_note),''), 'Rollback: ' || trim(p_reason)), 'manual_verified', auth.uid(), now())
  RETURNING * INTO pr;
  PERFORM set_config('vexim.publish_ctx', pr.id::text, true);
  UPDATE public.content_versions SET status = 'rolled_back', rollback_reason = trim(p_reason) WHERE id = v.id;
  RETURN pr;
END; $$;
GRANT EXECUTE ON FUNCTION public.record_rollback(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- Guard: chặn chuyển published khi policy yêu cầu bằng chứng mà không đi qua record_publish
CREATE OR REPLACE FUNCTION public.content_publish_evidence_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE req BOOLEAN; ctx TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status = 'published' AND OLD.status IS DISTINCT FROM 'published' THEN
    SELECT COALESCE(publish_evidence_required, true) INTO req FROM public.policy_register WHERE tenant_id = NEW.tenant_id;
    IF COALESCE(req, true) THEN
      ctx := current_setting('vexim.publish_ctx', true);
      IF ctx IS NULL OR ctx = '' OR NOT EXISTS (SELECT 1 FROM public.publish_records p WHERE p.id = ctx::uuid AND p.content_version_id = NEW.id AND p.kind = 'publish') THEN
        RAISE EXCEPTION 'Chính sách yêu cầu bằng chứng publish — dùng record_publish(version, url/ghi chú)';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_a_publish_evidence ON public.content_versions;
-- chạy TRƯỚC guard chính (thứ tự theo tên): 'trg_a_publish_evidence' < 'trg_content_versions_guard'
CREATE TRIGGER trg_a_publish_evidence BEFORE UPDATE ON public.content_versions FOR EACH ROW EXECUTE FUNCTION public.content_publish_evidence_guard();

-- ------------------------------------------------------------
-- 4. v_system_health — không giả định cron đang chạy
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.system_health()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE has_cron BOOLEAN; jobs JSONB := '[]'::jsonb; st TEXT; j RECORD; last_snap DATE; last_rule TIMESTAMPTZ; sp BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO has_cron;
  IF has_cron THEN
    BEGIN
      FOR j IN EXECUTE $q$ SELECT jobname, schedule, active FROM cron.job WHERE jobname LIKE 'vexim_%' $q$ LOOP
        jobs := jobs || jsonb_build_object('name', j.jobname, 'schedule', j.schedule, 'active', j.active);
      END LOOP;
      st := CASE WHEN jsonb_array_length(jobs) >= 3 THEN 'ok' ELSE 'missing' END;
    EXCEPTION WHEN OTHERS THEN st := 'unknown';
    END;
  ELSE st := 'missing';
  END IF;
  SELECT MAX(date) INTO last_snap FROM public.sku_daily_snapshots;
  SELECT MAX(started_at) INTO last_rule FROM public.rule_runs;
  SELECT EXISTS (SELECT 1 FROM public.data_sources WHERE kind = 'sp_api' AND status = 'connected') INTO sp;
  RETURN jsonb_build_object(
    'checked_at', now(), 'cron_status', st, 'cron_jobs', jobs,
    'last_snapshot_date', last_snap, 'last_rule_run_at', last_rule,
    'sp_api_connected_any', sp,
    'write_back_enabled', false,
    'note', CASE st WHEN 'ok' THEN 'pg_cron có 3 job vexim_*' WHEN 'missing' THEN 'pg_cron chưa bật hoặc thiếu job — snapshot/rule/forecast phải chạy tay' ELSE 'Không đọc được cron.job (quyền) — trạng thái không xác định' END);
END; $$;
GRANT EXECUTE ON FUNCTION public.system_health() TO authenticated;

-- ------------------------------------------------------------
-- Self-check
-- ------------------------------------------------------------
DO $$
DECLARE n INT; m INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns WHERE table_schema='public' AND table_name='actions' AND column_name IN ('execution_channel','amazon_applied');
  SELECT count(*) INTO m FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%');
  RAISE NOTICE '019 self-check: actions cols=% (kỳ vọng 2), publish_records=%, SECURITY DEFINER thiếu search_path=% (kỳ vọng 0), health=%',
    n, to_regclass('public.publish_records') IS NOT NULL, m, public.system_health()->>'cron_status';
END $$;
