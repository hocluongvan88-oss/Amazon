-- ============================================================
-- 014 — P0‑4: VoC‑to‑task + ASIN Control Room
--   tasks (hàng đợi hành động thống nhất, 5 loại từ VoC + content_opportunity)
--   create_tasks_from_ticket()  ·  auto‑suggest theo loại ticket
--   asin_control_room(sku)      ·  1 JSON gộp margin/risk/inventory/content/VoC/tasks
-- Chạy SAU 013. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. tasks
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tasks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku_id        UUID REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  asin          TEXT,
  -- loại task (theo PRODUCT_SCOPE §3)
  type          TEXT NOT NULL CHECK (type IN ('content','qa_product','ads_guardrail','support','inventory_investigation','content_opportunity','other')),
  title         TEXT NOT NULL,
  description   TEXT,
  priority      TEXT NOT NULL DEFAULT 'P2' CHECK (priority IN ('P0','P1','P2','P3')),
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','blocked','done','cancelled')),
  -- nguồn gốc (evidence)
  source_type   TEXT NOT NULL CHECK (source_type IN ('voc_ticket','listing_audit','exception','recommendation','manual')),
  source_id     UUID,
  evidence      JSONB NOT NULL DEFAULT '{}'::jsonb,   -- {review_ids, topic_code, reasons, ...}
  -- liên kết kết quả
  linked_content_version UUID REFERENCES public.content_versions(id) ON DELETE SET NULL,
  linked_recommendation  UUID REFERENCES public.recommendations(id) ON DELETE SET NULL,
  assigned_to   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  due_at        TIMESTAMPTZ,
  created_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  done_by       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  done_at       TIMESTAMPTZ,
  outcome       TEXT,                                  -- kết quả khi done/cancelled (bắt buộc)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tasks_tenant_status ON public.tasks(tenant_id, status, priority, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_sku ON public.tasks(sku_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_source ON public.tasks(source_type, source_id);

-- Permission cần để tạo/xử lý từng loại task
CREATE OR REPLACE FUNCTION public.task_permission(p_type TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'content' THEN 'content.draft'
    WHEN 'content_opportunity' THEN 'content.draft'
    WHEN 'qa_product' THEN 'exception.resolve'
    WHEN 'ads_guardrail' THEN 'rec.create'
    WHEN 'inventory_investigation' THEN 'exception.resolve'
    WHEN 'support' THEN 'voc.triage'
    ELSE 'exception.resolve' END;
$$;

CREATE OR REPLACE FUNCTION public.task_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid();
BEGIN
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := COALESCE(NEW.created_by, uid);
    IF NEW.asin IS NULL AND NEW.sku_id IS NOT NULL THEN SELECT asin INTO NEW.asin FROM public.amazon_skus WHERE id = NEW.sku_id; END IF;
    IF NEW.due_at IS NULL THEN
      NEW.due_at := now() + CASE NEW.priority WHEN 'P0' THEN interval '1 day' WHEN 'P1' THEN interval '3 days' WHEN 'P2' THEN interval '7 days' ELSE interval '14 days' END;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF uid IS NOT NULL AND NOT (public.has_permission(NEW.tenant_id, public.task_permission(NEW.type)) OR public.has_permission(NEW.tenant_id, 'voc.triage')) THEN
      RAISE EXCEPTION 'Không đủ quyền xử lý task loại % (cần %)', NEW.type, public.task_permission(NEW.type);
    END IF;
    IF NEW.status IN ('done','cancelled') THEN
      IF COALESCE(trim(NEW.outcome),'') = '' THEN RAISE EXCEPTION 'Đóng task phải ghi kết quả (outcome)'; END IF;
      NEW.done_by := uid; NEW.done_at := now();
    ELSIF OLD.status IN ('done','cancelled') THEN
      NEW.done_by := NULL; NEW.done_at := NULL; NEW.outcome := NULL;
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_tasks_guard ON public.tasks;
CREATE TRIGGER trg_tasks_guard BEFORE INSERT OR UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION public.task_guard();

-- ------------------------------------------------------------
-- 2. VoC → task
-- ------------------------------------------------------------
-- Gợi ý loại task theo loại ticket (UI hiển thị để người dùng chọn; không tự tạo)
CREATE OR REPLACE FUNCTION public.suggest_tasks_for_ticket(p_ticket UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE tk public.voc_tickets%ROWTYPE; out JSONB := '[]'::jsonb; n_reviews INT; oos BOOLEAN := false; ad NUMERIC := 0;
BEGIN
  SELECT * INTO tk FROM public.voc_tickets WHERE id = p_ticket;
  IF tk.id IS NULL THEN RETURN out; END IF;
  n_reviews := COALESCE(array_length(tk.review_ids,1),0);
  IF tk.sku_id IS NOT NULL THEN
    SELECT COALESCE(SUM(ad_spend),0), bool_or(inventory_qty = 0) INTO ad, oos FROM public.sku_daily_snapshots WHERE sku_id = tk.sku_id AND date > CURRENT_DATE - 14;
  END IF;

  CASE tk.type
    WHEN 'defect' THEN
      out := out || jsonb_build_object('type','qa_product','priority', CASE WHEN n_reviews >= 3 OR tk.priority IN ('P0','P1') THEN 'P1' ELSE 'P2' END,
        'title', format('Kiểm tra chất lượng: %s', tk.title), 'why', format('%s review báo lỗi sản phẩm – kiểm tra batch/nhà cung cấp', n_reviews));
      out := out || jsonb_build_object('type','content','priority','P2',
        'title', format('Cập nhật listing để phòng ngừa: %s', tk.title), 'why','Giải thích cách dùng đúng / giới hạn sản phẩm trong bullets hoặc A+ để giảm kỳ vọng sai');
      IF ad > 0 THEN out := out || jsonb_build_object('type','ads_guardrail','priority','P1',
        'title', format('Cân nhắc giảm traffic quảng cáo vào ASIN %s', tk.asin), 'why', format('Đang chi %s USD ads/14 ngày vào SKU có lỗi được xác nhận – tránh khuếch đại review xấu', round(ad))); END IF;
      out := out || jsonb_build_object('type','support','priority','P2', 'title','Liên hệ khách hàng bị ảnh hưởng (Brand Registry, 1–3★)', 'why','Chỉ mẫu Customer support/Courtesy refund; không yêu cầu sửa review');
    WHEN 'content' THEN
      out := out || jsonb_build_object('type','content','priority','P1',
        'title', format('Sửa nội dung listing: %s', tk.title), 'why','Khách hiểu sai vì mô tả/ảnh – nguồn trực tiếp cho draft mới trong Content Studio');
      out := out || jsonb_build_object('type','content_opportunity','priority','P2', 'title','Rà soát Product Facts liên quan', 'why','Đảm bảo có fact đã xác minh trước khi sửa claim');
    WHEN 'logistics' THEN
      out := out || jsonb_build_object('type','inventory_investigation','priority','P2',
        'title', format('Điều tra đóng gói / FBA prep: %s', tk.title), 'why','Hư hỏng vận chuyển – kiểm tra prep, thùng, inbound gần nhất');
      out := out || jsonb_build_object('type','support','priority','P2', 'title','Hỗ trợ khách bị ảnh hưởng', 'why','Courtesy refund / thay thế qua Brand Registry');
    WHEN 'service' THEN
      out := out || jsonb_build_object('type','support','priority','P1', 'title', format('Xử lý dịch vụ: %s', tk.title), 'why','Phản hồi khách trong SLA');
    ELSE
      out := out || jsonb_build_object('type','other','priority','P3', 'title', tk.title, 'why','Cần phân loại thêm');
  END CASE;
  IF oos THEN out := out || jsonb_build_object('type','inventory_investigation','priority','P1', 'title', format('ASIN %s có ngày hết hàng trong 14 ngày qua', tk.asin), 'why','Hết hàng + review xấu làm giảm rank kép'); END IF;
  RETURN out;
END; $$;
GRANT EXECUTE ON FUNCTION public.suggest_tasks_for_ticket(UUID) TO authenticated;

-- Tạo task từ ticket (danh sách đã chọn). Idempotent theo (ticket, type, title).
CREATE OR REPLACE FUNCTION public.create_tasks_from_ticket(p_ticket UUID, p_tasks JSONB)
RETURNS SETOF public.tasks LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tk public.voc_tickets%ROWTYPE; it JSONB; t public.tasks;
BEGIN
  SELECT * INTO tk FROM public.voc_tickets WHERE id = p_ticket;
  IF tk.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy ticket'; END IF;
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(tk.tenant_id, 'voc.triage') THEN RAISE EXCEPTION 'Không đủ quyền (voc.triage)'; END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_tasks) LOOP
    SELECT * INTO t FROM public.tasks WHERE source_type = 'voc_ticket' AND source_id = tk.id AND type = it->>'type' AND title = it->>'title' AND status <> 'cancelled';
    IF t.id IS NULL THEN
      INSERT INTO public.tasks (tenant_id, sku_id, asin, type, title, description, priority, source_type, source_id, evidence)
      VALUES (tk.tenant_id, tk.sku_id, tk.asin, it->>'type', it->>'title', COALESCE(it->>'description', it->>'why'), COALESCE(it->>'priority', tk.priority), 'voc_ticket', tk.id,
              jsonb_build_object('ticket_id', tk.id, 'ticket_type', tk.type, 'topic_code', tk.topic_code, 'review_ids', to_jsonb(tk.review_ids), 'why', it->>'why'))
      RETURNING * INTO t;
    END IF;
    RETURN NEXT t;
  END LOOP;
  IF tk.status = 'open' THEN UPDATE public.voc_tickets SET status = 'investigating' WHERE id = tk.id; END IF;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_tasks_from_ticket(UUID, JSONB) TO authenticated;

-- Task content_opportunity từ listing audit (điểm ≥ ngưỡng). Idempotent theo sku khi còn task mở.
CREATE OR REPLACE FUNCTION public.create_content_opportunity_tasks(t UUID, p_min_score INT DEFAULT 50)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD; n INT := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(t, 'content.draft') THEN RAISE EXCEPTION 'Không đủ quyền (content.draft)'; END IF;
  FOR r IN SELECT * FROM public.v_listing_audit a WHERE a.tenant_id = t AND a.opportunity_score >= p_min_score LOOP
    IF NOT EXISTS (SELECT 1 FROM public.tasks WHERE sku_id = r.sku_id AND type = 'content_opportunity' AND status IN ('open','in_progress','blocked')) THEN
      INSERT INTO public.tasks (tenant_id, sku_id, asin, type, title, description, priority, source_type, evidence)
      VALUES (t, r.sku_id, r.asin, 'content_opportunity', format('Cơ hội content %s điểm – %s', r.opportunity_score, r.asin), array_to_string(r.reasons, E'\n'),
              CASE WHEN r.opportunity_score >= 75 THEN 'P1' ELSE 'P2' END, 'listing_audit',
              jsonb_build_object('score', r.opportunity_score, 'reasons', to_jsonb(r.reasons), 'cvr_30d', r.cvr_30d, 'cvr_median', r.cvr_median, 'neg_reviews_90d', r.neg_reviews_90d));
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_content_opportunity_tasks(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 3. ASIN Control Room — 1 JSON cho trang SKU
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.asin_control_room(p_sku UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE k public.amazon_skus%ROWTYPE; m RECORD; res JSONB; risk NUMERIC; pol public.policy_register%ROWTYPE;
BEGIN
  SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  IF k.id IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS NOT NULL AND NOT (k.tenant_id IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = k.tenant_id;
  SELECT * INTO m FROM public.sku_metrics(k.tenant_id, CURRENT_DATE, p_sku) LIMIT 1;
  SELECT risk_score INTO risk FROM public.risk_history WHERE sku_id = p_sku ORDER BY date DESC LIMIT 1;

  res := jsonb_build_object(
    'sku', jsonb_build_object('id', k.id, 'asin', k.asin, 'title', k.title, 'price', k.current_price, 'cogs', k.cogs, 'inventory_qty', k.inventory_qty, 'is_canary', k.asin = ANY(COALESCE(pol.canary_asins, '{}'))),
    'revenue', jsonb_build_object('units_30d', m.units_30d, 'revenue_30d', m.revenue_30d, 'cp_30d', m.cp_30d, 'velocity_7d', m.velocity_7d, 'velocity_30d', m.velocity_30d, 'velocity_change_pct', m.velocity_change_pct, 'cvr_30', m.cvr_30, 'last_sale_date', m.last_sale_date),
    'margin',  jsonb_build_object('cp_unit_now', m.cp_unit_now, 'cp_margin_now_pct', m.cp_margin_now_pct, 'cp_margin_baseline_pct', m.cp_margin_baseline_pct, 'margin_delta_pts', m.margin_delta_pts, 'min_margin_pct', pol.min_margin_pct,
                                  'below_min', COALESCE(m.cp_margin_now_pct, 0) < COALESCE(pol.min_margin_pct, 0)),
    'ads',     jsonb_build_object('ad_spend_30', m.ad_spend_30, 'acos_30', m.acos_30, 'tacos_30', m.tacos_30,
                                  'break_even_acos_pct', CASE WHEN k.current_price > 0 THEN round(100 * (k.current_price - k.cogs - k.fee_per_unit - k.current_price * k.referral_fee_pct / 100) / k.current_price, 1) END),
    'inventory', jsonb_build_object('days_of_cover', m.days_of_cover, 'stockout_eta', m.stockout_eta, 'health', m.inventory_health),
    'risk', jsonb_build_object('score', risk),
    'content', (SELECT jsonb_build_object(
        'facts_verified', (SELECT count(*) FROM public.product_facts WHERE sku_id = p_sku AND status = 'verified'),
        'facts_proposed', (SELECT count(*) FROM public.product_facts WHERE sku_id = p_sku AND status = 'proposed'),
        'published', (SELECT COALESCE(jsonb_object_agg(kind, version), '{}'::jsonb) FROM public.content_versions WHERE sku_id = p_sku AND status = 'published'),
        'in_flight', (SELECT count(*) FROM public.content_versions WHERE sku_id = p_sku AND status IN ('draft','qa_review','qa_passed','awaiting_brand_approval','approved')),
        'opportunity_score', (SELECT opportunity_score FROM public.v_listing_audit WHERE sku_id = p_sku),
        'reasons', (SELECT to_jsonb(reasons) FROM public.v_listing_audit WHERE sku_id = p_sku))),
    'voc', jsonb_build_object(
        'neg_reviews_90d', (SELECT count(*) FROM public.raw_reviews WHERE tenant_id = k.tenant_id AND asin = k.asin AND rating <= 3 AND COALESCE(reviewed_at, created_at) > now() - interval '90 days'),
        'open_tickets', (SELECT count(*) FROM public.voc_tickets WHERE sku_id = p_sku AND status IN ('open','investigating')),
        'top_topics', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code', x.topic_code, 'n', x.n) ORDER BY x.n DESC), '[]'::jsonb) FROM (
            SELECT c.topic_code, count(*) AS n FROM public.review_classifications c JOIN public.raw_reviews r ON r.id = c.review_id
            WHERE r.tenant_id = k.tenant_id AND r.asin = k.asin AND r.rating <= 3 GROUP BY c.topic_code ORDER BY n DESC LIMIT 3) x)),
    'queue', jsonb_build_object(
        'recommendations_pending', (SELECT count(*) FROM public.recommendations WHERE sku_id = p_sku AND status IN ('draft','pending_approval','approved')),
        'exceptions_open', (SELECT count(*) FROM public.exceptions WHERE tenant_id = k.tenant_id AND asin = k.asin AND NOT resolved),
        'tasks_open', (SELECT count(*) FROM public.tasks WHERE sku_id = p_sku AND status IN ('open','in_progress','blocked')),
        'tasks_by_type', (SELECT COALESCE(jsonb_object_agg(type, n), '{}'::jsonb) FROM (SELECT type, count(*) n FROM public.tasks WHERE sku_id = p_sku AND status IN ('open','in_progress','blocked') GROUP BY type) s)),
    'actions', jsonb_build_object(
        'last_action', (SELECT jsonb_build_object('type', action_type, 'mode', mode, 'status', status, 'at', finished_at) FROM public.actions WHERE sku_id = p_sku AND mode <> 'dry_run' ORDER BY created_at DESC LIMIT 1),
        'in_watch', (SELECT count(*) FROM public.actions WHERE sku_id = p_sku AND status = 'succeeded' AND watch_until > now()))
  );

  -- Tín hiệu chéo (cross‑domain signals) — lý do "vì sao cần nhìn ASIN này"
  res := res || jsonb_build_object('signals', (
    SELECT COALESCE(jsonb_agg(s), '[]'::jsonb) FROM (
      SELECT jsonb_build_object('level','high','msg', format('Biên %s%% dưới mức tối thiểu %s%%', round(COALESCE(m.cp_margin_now_pct,0),1), pol.min_margin_pct)) s WHERE COALESCE(m.cp_margin_now_pct,0) < COALESCE(pol.min_margin_pct,0)
      UNION ALL SELECT jsonb_build_object('level','high','msg', format('Hết hàng dự kiến %s (%s ngày tồn)', m.stockout_eta, round(COALESCE(m.days_of_cover,0)))) WHERE m.days_of_cover IS NOT NULL AND m.days_of_cover < COALESCE(pol.default_lead_time_days, 30)
      UNION ALL SELECT jsonb_build_object('level','high','msg', format('ACoS %s%% vượt break‑even %s%%', round(m.acos_30,1), round(100 * (k.current_price - k.cogs - k.fee_per_unit - k.current_price * k.referral_fee_pct / 100) / NULLIF(k.current_price,0),1))) WHERE m.acos_30 IS NOT NULL AND k.current_price > 0 AND m.acos_30 > 100 * (k.current_price - k.cogs - k.fee_per_unit - k.current_price * k.referral_fee_pct / 100) / k.current_price
      UNION ALL SELECT jsonb_build_object('level','medium','msg', format('Velocity %s%% so với 30 ngày', round(m.velocity_change_pct))) WHERE m.velocity_change_pct IS NOT NULL AND m.velocity_change_pct < -25
      UNION ALL SELECT jsonb_build_object('level','medium','msg', format('%s review ≤3★ trong 90 ngày, %s ticket mở', (res->'voc'->>'neg_reviews_90d'), (res->'voc'->>'open_tickets'))) WHERE (res->'voc'->>'neg_reviews_90d')::int >= 3
      UNION ALL SELECT jsonb_build_object('level','medium','msg', format('Cơ hội content %s điểm', (res->'content'->>'opportunity_score'))) WHERE (res->'content'->>'opportunity_score')::int >= 50
      UNION ALL SELECT jsonb_build_object('level','low','msg', format('%s task đang mở', (res->'queue'->>'tasks_open'))) WHERE (res->'queue'->>'tasks_open')::int > 0
      UNION ALL SELECT jsonb_build_object('level','info','msg', 'Có hành động đang trong cửa sổ theo dõi rollback') WHERE (res->'actions'->>'in_watch')::int > 0
    ) q(s)));
  RETURN res;
END; $$;
GRANT EXECUTE ON FUNCTION public.asin_control_room(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 4. RLS + audit
-- ------------------------------------------------------------
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tasks_select ON public.tasks; DROP POLICY IF EXISTS tasks_insert ON public.tasks; DROP POLICY IF EXISTS tasks_update ON public.tasks;
CREATE POLICY tasks_select ON public.tasks FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY tasks_insert ON public.tasks FOR INSERT TO authenticated
  WITH CHECK (public.has_permission(tenant_id, 'voc.triage') OR public.has_permission(tenant_id, 'content.draft') OR public.has_permission(tenant_id, 'exception.resolve'));
CREATE POLICY tasks_update ON public.tasks FOR UPDATE TO authenticated
  USING (public.has_permission(tenant_id, 'voc.triage') OR public.has_permission(tenant_id, 'content.draft') OR public.has_permission(tenant_id, 'exception.resolve') OR public.has_permission(tenant_id, 'rec.create'))
  WITH CHECK (public.has_permission(tenant_id, 'voc.triage') OR public.has_permission(tenant_id, 'content.draft') OR public.has_permission(tenant_id, 'exception.resolve') OR public.has_permission(tenant_id, 'rec.create'));

DROP TRIGGER IF EXISTS trg_tasks_audit ON public.tasks;
CREATE TRIGGER trg_tasks_audit AFTER INSERT OR UPDATE OR DELETE ON public.tasks FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- Kiểm tra nhanh
-- SELECT public.asin_control_room((SELECT id FROM public.amazon_skus LIMIT 1));
