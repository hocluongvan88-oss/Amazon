-- ============================================================
-- 009 — Review / VOC: listening & triage  (Tuần 9‑10)
-- Chạy SAU 008. Idempotent.
-- Nguyên tắc: chỉ lắng nghe, phân loại, mở ticket, soạn nháp phản hồi có kiểm tra chính sách và người duyệt.
-- KHÔNG có hành động nào tác động rating (xin đổi sao, ưu đãi đổi review, yêu cầu gỡ review…).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Policy: từ/cụm bị cấm trong phản hồi
-- ------------------------------------------------------------
ALTER TABLE public.policy_register
  ADD COLUMN IF NOT EXISTS prohibited_phrases JSONB NOT NULL DEFAULT '[
    "đổi đánh giá","sửa đánh giá","xóa đánh giá","xoá đánh giá","gỡ đánh giá","5 sao","năm sao","đánh giá lại","tặng quà","hoàn tiền nếu","voucher","mã giảm giá","liên hệ ngoài amazon","zalo","whatsapp","email cho chúng tôi",
    "change your review","update your review","edit your review","remove your review","delete your review","revise your review","5 star","five star","5-star","re-rate","in exchange","refund if you","gift card","coupon","discount code","contact us outside","contact us directly at","reach out to us at","email us at","whatsapp"
  ]'::jsonb,
  ADD COLUMN IF NOT EXISTS review_triage_max_rating INTEGER NOT NULL DEFAULT 3;

-- ------------------------------------------------------------
-- 2. Chủ đề review
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.review_topics (
  tenant_id  UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  code       TEXT NOT NULL,
  label      TEXT NOT NULL,
  type       TEXT NOT NULL CHECK (type IN ('defect','content','logistics','service','positive','other')),
  keywords   TEXT[] NOT NULL DEFAULT '{}',
  severity_default INTEGER NOT NULL DEFAULT 2 CHECK (severity_default BETWEEN 1 AND 3),  -- 3 = nghiêm trọng
  active     BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, code)
);

CREATE OR REPLACE FUNCTION public.seed_review_topics(t UUID)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.review_topics (tenant_id, code, label, type, keywords, severity_default) VALUES
  (t,'BROKEN',      'Hư hỏng / vỡ / nứt',        'defect',    ARRAY['broke','broken','crack','cracked','snapped','shatter','fell apart','defective','damaged','vỡ','nứt','gãy','hỏng','hư','bể'], 3),
  (t,'QUALITY',     'Chất lượng kém',            'defect',    ARRAY['cheap','poor quality','flimsy','low quality','thin','fragile','rough','splinter','peel','peeling','fade','faded','rust','kém','mỏng','tệ','dở','xù xì','bong tróc','phai màu','rỉ'], 2),
  (t,'SMELL',       'Mùi / hoá chất',            'defect',    ARRAY['smell','odor','odour','chemical','stink','toxic','mùi','hôi','hoá chất','hóa chất'], 3),
  (t,'SAFETY',      'An toàn / dị ứng',          'defect',    ARRAY['burn','burned','cut myself','sharp','injur','rash','allerg','choking','mold','mould','bỏng','đứt tay','sắc','dị ứng','mốc','nấm mốc'], 3),
  (t,'SIZE',        'Kích thước / mô tả sai',    'content',   ARRAY['smaller','too small','too big','not as described','misleading','different from picture','not what','wrong size','size','dimension','nhỏ hơn','to hơn','không giống','sai kích thước','khác hình'], 2),
  (t,'COLOR',       'Màu sắc khác hình',         'content',   ARRAY['color','colour','darker','lighter','not the color','màu','đậm hơn','nhạt hơn','khác màu'], 1),
  (t,'INSTRUCTIONS','Hướng dẫn / lắp ráp',       'content',   ARRAY['instruction','manual','assembly','assemble','hard to use','confusing','hướng dẫn','lắp ráp','khó dùng'], 1),
  (t,'PACKAGING',   'Đóng gói',                  'logistics', ARRAY['packag','box was','arrived damaged','dented','crushed','no padding','bubble','đóng gói','hộp móp','hộp rách','bể hộp'], 2),
  (t,'SHIPPING',    'Giao hàng / trễ',           'logistics', ARRAY['late','delay','never arrived','shipping','delivery','lost package','took forever','giao trễ','giao chậm','chưa nhận','thất lạc'], 2),
  (t,'WRONG_ITEM',  'Giao sai / thiếu',          'logistics', ARRAY['wrong item','wrong product','missing','incomplete','not included','received a different','giao sai','thiếu','không có trong hộp'], 3),
  (t,'PRICE',       'Giá / giá trị',             'service',   ARRAY['overpriced','expensive','not worth','waste of money','rip off','đắt','không đáng','phí tiền'], 1),
  (t,'SUPPORT',     'Hỗ trợ / hoàn trả',         'service',   ARRAY['customer service','support','return','refund','no response','ignored','hỗ trợ','hoàn trả','hoàn tiền','không phản hồi'], 2),
  (t,'POSITIVE',    'Khen ngợi',                 'positive',  ARRAY['love','great','excellent','perfect','beautiful','amazing','highly recommend','works well','sturdy','well made','rất thích','tuyệt','đẹp','chắc chắn','hài lòng','đáng tiền'], 1)
  ON CONFLICT (tenant_id, code) DO NOTHING;
$$;
SELECT public.seed_review_topics(id) FROM public.tenants;

-- ------------------------------------------------------------
-- 3. Phân loại review
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.review_classifications (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  review_id    UUID NOT NULL REFERENCES public.raw_reviews(id) ON DELETE CASCADE,
  topic_code   TEXT NOT NULL,
  sentiment    TEXT NOT NULL CHECK (sentiment IN ('negative','neutral','positive')),
  severity     INTEGER NOT NULL CHECK (severity BETWEEN 1 AND 3),
  confidence   NUMERIC(4,2) NOT NULL DEFAULT 0.5,
  method       TEXT NOT NULL DEFAULT 'rules' CHECK (method IN ('rules','llm','human')),
  matched      TEXT[],                               -- từ khoá khớp (giải thích được)
  -- QA
  verified_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  verified_at  TIMESTAMPTZ,
  verified_ok  BOOLEAN,                              -- TRUE đúng / FALSE sai
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (review_id, topic_code)
);
CREATE INDEX IF NOT EXISTS idx_rc_tenant ON public.review_classifications(tenant_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.classify_review(p_review UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.raw_reviews%ROWTYPE; txt TEXT; tp RECORD; kw TEXT; hits TEXT[]; n INT := 0; sent TEXT; sev INT; has_topic BOOLEAN := FALSE;
BEGIN
  SELECT * INTO r FROM public.raw_reviews WHERE id = p_review;
  IF r.id IS NULL OR r.tenant_id IS NULL THEN RETURN 0; END IF;
  txt := lower(coalesce(r.title, '') || ' ' || coalesce(r.body, ''));
  sent := CASE WHEN r.rating <= 2 THEN 'negative' WHEN r.rating = 3 THEN 'neutral' ELSE 'positive' END;
  -- không ghi đè phân loại do người sửa
  DELETE FROM public.review_classifications WHERE review_id = p_review AND method <> 'human';

  FOR tp IN SELECT * FROM public.review_topics WHERE tenant_id = r.tenant_id AND active LOOP
    hits := ARRAY[]::text[];
    FOREACH kw IN ARRAY tp.keywords LOOP
      IF position(lower(kw) IN txt) > 0 THEN hits := array_append(hits, kw); END IF;
    END LOOP;
    IF array_length(hits, 1) > 0 THEN
      -- chủ đề positive chỉ áp cho review ≥ 4★; chủ đề lỗi áp cho mọi sao nhưng hạ severity nếu ≥ 4★
      CONTINUE WHEN tp.type = 'positive' AND r.rating < 4;
      sev := CASE WHEN r.rating >= 4 THEN 1 WHEN r.rating <= 2 THEN tp.severity_default ELSE GREATEST(1, tp.severity_default - 1) END;
      IF tp.type = 'positive' THEN sev := 1; END IF;
      INSERT INTO public.review_classifications (tenant_id, review_id, topic_code, sentiment, severity, confidence, method, matched)
      VALUES (r.tenant_id, p_review, tp.code, sent, sev, LEAST(0.95, 0.55 + 0.15 * array_length(hits, 1)), 'rules', hits)
      ON CONFLICT (review_id, topic_code) DO NOTHING;
      n := n + 1; has_topic := TRUE;
    END IF;
  END LOOP;
  IF NOT has_topic THEN
    INSERT INTO public.review_classifications (tenant_id, review_id, topic_code, sentiment, severity, confidence, method, matched)
    VALUES (r.tenant_id, p_review, 'UNCLASSIFIED', sent, CASE WHEN r.rating <= 2 THEN 2 ELSE 1 END, 0.3, 'rules', NULL)
    ON CONFLICT (review_id, topic_code) DO NOTHING;
    n := 1;
  END IF;
  RETURN n;
END; $$;

CREATE OR REPLACE FUNCTION public.classify_reviews(t UUID, only_new BOOLEAN DEFAULT TRUE)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT := 0; r RECORD;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_role(t, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
  FOR r IN SELECT rv.id FROM public.raw_reviews rv WHERE rv.tenant_id = t
           AND (NOT only_new OR NOT EXISTS (SELECT 1 FROM public.review_classifications c WHERE c.review_id = rv.id)) LOOP
    PERFORM public.classify_review(r.id); n := n + 1;
  END LOOP;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.classify_review(UUID), public.classify_reviews(UUID, BOOLEAN) TO authenticated;

-- tự phân loại khi có review mới
CREATE OR REPLACE FUNCTION public.trg_classify_review()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM public.classify_review(NEW.id); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_reviews_classify ON public.raw_reviews;
CREATE TRIGGER trg_reviews_classify AFTER INSERT ON public.raw_reviews FOR EACH ROW EXECUTE FUNCTION public.trg_classify_review();

-- ------------------------------------------------------------
-- 4. VOC tickets
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.voc_tickets (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  asin          TEXT NOT NULL,
  sku_id        UUID REFERENCES public.amazon_skus(id) ON DELETE SET NULL,
  type          TEXT NOT NULL CHECK (type IN ('defect','content','logistics','service','other')),
  topic_code    TEXT,
  priority      TEXT NOT NULL DEFAULT 'P2' CHECK (priority IN ('P0','P1','P2','P3')),
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','investigating','resolved','wont_fix')),
  title         TEXT NOT NULL,
  description   TEXT,
  review_ids    UUID[] NOT NULL DEFAULT '{}',
  assigned_to   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at   TIMESTAMPTZ,
  resolution_note TEXT
);
CREATE INDEX IF NOT EXISTS idx_voc_tenant ON public.voc_tickets(tenant_id, status, created_at DESC);

CREATE OR REPLACE FUNCTION public.voc_ticket_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  IF NEW.created_by IS NULL THEN NEW.created_by := auth.uid(); END IF;
  IF NEW.sku_id IS NULL THEN SELECT id INTO NEW.sku_id FROM public.amazon_skus WHERE tenant_id = NEW.tenant_id AND asin = NEW.asin LIMIT 1; END IF;
  IF NEW.status IN ('resolved','wont_fix') AND (TG_OP = 'INSERT' OR OLD.status NOT IN ('resolved','wont_fix')) THEN NEW.resolved_at := now(); END IF;
  IF NEW.status IN ('open','investigating') THEN NEW.resolved_at := NULL; END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_voc_touch ON public.voc_tickets;
CREATE TRIGGER trg_voc_touch BEFORE INSERT OR UPDATE ON public.voc_tickets FOR EACH ROW EXECUTE FUNCTION public.voc_ticket_touch();

-- ------------------------------------------------------------
-- 5. Nháp phản hồi + kiểm tra chính sách + duyệt người
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_response_policy(t UUID, body TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE pol public.policy_register%ROWTYPE; ph TEXT; viol TEXT[] := '{}'; warn TEXT[] := '{}'; txt TEXT := lower(coalesce(body, ''));
BEGIN
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = t;
  FOR ph IN SELECT jsonb_array_elements_text(coalesce(pol.prohibited_phrases, '[]'::jsonb)) LOOP
    IF position(lower(ph) IN txt) > 0 THEN viol := array_append(viol, ph); END IF;
  END LOOP;
  IF length(txt) < 40 THEN warn := array_append(warn, 'Quá ngắn (< 40 ký tự)'); END IF;
  IF length(txt) > 1200 THEN warn := array_append(warn, 'Quá dài (> 1200 ký tự)'); END IF;
  IF txt ~ '(http|www\.)' THEN viol := array_append(viol, 'đường link'); END IF;
  IF txt ~ '[0-9]{3}[ .-]?[0-9]{3}[ .-]?[0-9]{3,4}' THEN viol := array_append(viol, 'số điện thoại'); END IF;
  IF txt ~ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' THEN viol := array_append(viol, 'địa chỉ email'); END IF;
  IF NOT (txt ~ '(xin lỗi|rất tiếc|cảm ơn|sorry|apolog|thank)') THEN warn := array_append(warn, 'Thiếu lời cảm ơn / xin lỗi'); END IF;
  RETURN jsonb_build_object('ok', coalesce(array_length(viol, 1), 0) = 0, 'violations', to_jsonb(viol), 'warnings', to_jsonb(warn), 'checked_at', now());
END; $$;
GRANT EXECUTE ON FUNCTION public.check_response_policy(UUID, TEXT) TO authenticated;

CREATE TABLE IF NOT EXISTS public.response_drafts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  review_id     UUID NOT NULL REFERENCES public.raw_reviews(id) ON DELETE CASCADE,
  ticket_id     UUID REFERENCES public.voc_tickets(id) ON DELETE SET NULL,
  body          TEXT NOT NULL,
  channel       TEXT NOT NULL DEFAULT 'buyer_message' CHECK (channel IN ('buyer_message','public_comment','internal_note')),
  status        TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','pending_approval','approved','rejected','sent')),
  policy_check  JSONB,
  created_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at   TIMESTAMPTZ,
  rejected_reason TEXT,
  sent_at       TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_drafts_tenant ON public.response_drafts(tenant_id, status, created_at DESC);

-- Guard: luôn chạy policy check; không cho duyệt/gửi khi vi phạm; người duyệt ≠ người soạn (trừ khi chỉ có 1 thành viên); từ chối phải có lý do
CREATE OR REPLACE FUNCTION public.response_draft_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid(); members INT;
BEGIN
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' AND NEW.created_by IS NULL THEN NEW.created_by := uid; END IF;
  IF TG_OP = 'INSERT' OR NEW.body IS DISTINCT FROM OLD.body THEN
    NEW.policy_check := public.check_response_policy(NEW.tenant_id, NEW.body);
    IF TG_OP = 'UPDATE' AND OLD.status IN ('approved','sent') THEN RAISE EXCEPTION 'Không sửa nội dung đã duyệt/đã gửi'; END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status IN ('pending_approval','approved','sent') AND NOT (NEW.policy_check->>'ok')::boolean THEN
      RAISE EXCEPTION 'Nháp vi phạm chính sách phản hồi: %', NEW.policy_check->'violations';
    END IF;
    IF NEW.status = 'approved' THEN
      IF uid IS NOT NULL AND NOT public.has_role(NEW.tenant_id, ARRAY['owner','operator']) THEN RAISE EXCEPTION 'Không đủ quyền duyệt'; END IF;
      SELECT count(*) INTO members FROM public.tenant_members WHERE tenant_id = NEW.tenant_id;
      IF uid IS NOT NULL AND uid = NEW.created_by AND members > 1 THEN RAISE EXCEPTION 'Người duyệt phải khác người soạn'; END IF;
      NEW.approved_by := uid; NEW.approved_at := now();
    END IF;
    IF NEW.status = 'rejected' AND coalesce(trim(NEW.rejected_reason), '') = '' THEN RAISE EXCEPTION 'Từ chối phải có lý do'; END IF;
    IF NEW.status = 'sent' THEN
      IF OLD.status <> 'approved' THEN RAISE EXCEPTION 'Chỉ đánh dấu đã gửi sau khi duyệt'; END IF;
      NEW.sent_at := now();
    END IF;
    IF NEW.status = 'draft' THEN NEW.approved_by := NULL; NEW.approved_at := NULL; NEW.rejected_reason := NULL; END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_response_draft_guard ON public.response_drafts;
CREATE TRIGGER trg_response_draft_guard BEFORE INSERT OR UPDATE ON public.response_drafts FOR EACH ROW EXECUTE FUNCTION public.response_draft_guard();

-- Gợi ý nháp theo mẫu (không AI): dựa trên chủ đề chính; người soạn chỉnh trước khi gửi duyệt
CREATE OR REPLACE FUNCTION public.suggest_response(p_review UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.raw_reviews%ROWTYPE; topic TEXT; ttype TEXT; body TEXT;
BEGIN
  SELECT * INTO r FROM public.raw_reviews WHERE id = p_review;
  SELECT c.topic_code, t.type INTO topic, ttype FROM public.review_classifications c
    LEFT JOIN public.review_topics t ON t.tenant_id = c.tenant_id AND t.code = c.topic_code
    WHERE c.review_id = p_review ORDER BY c.severity DESC, c.confidence DESC LIMIT 1;
  body := 'Thank you for taking the time to share your experience. We are sorry the product did not meet your expectations. ';
  body := body || CASE ttype
    WHEN 'defect'    THEN 'What you described should not happen and we are reviewing it with our production team. '
    WHEN 'logistics' THEN 'We are reviewing this with our fulfilment partner to understand what went wrong during shipping and packaging. '
    WHEN 'content'   THEN 'We are updating our product page so the description and images are clearer for future customers. '
    WHEN 'service'   THEN 'We want to make this right. '
    ELSE 'We would like to learn more so we can improve. ' END;
  body := body || 'If you would like assistance with your order, you can reach us through your Amazon order page and we will respond promptly.';
  RETURN body;
END; $$;
GRANT EXECUTE ON FUNCTION public.suggest_response(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 6. Views
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_review_triage WITH (security_invoker = true) AS
SELECT r.id, r.tenant_id, r.asin, k.id AS sku_id, k.title AS sku_title, r.rating, r.title, r.body, r.verified_purchase, r.reviewed_at, r.created_at,
       (SELECT array_agg(c.topic_code ORDER BY c.severity DESC) FROM public.review_classifications c WHERE c.review_id = r.id) AS topics,
       (SELECT max(c.severity) FROM public.review_classifications c WHERE c.review_id = r.id) AS severity,
       EXISTS (SELECT 1 FROM public.voc_tickets v WHERE v.tenant_id = r.tenant_id AND r.id = ANY(v.review_ids)) AS has_ticket,
       (SELECT d.status FROM public.response_drafts d WHERE d.review_id = r.id ORDER BY d.created_at DESC LIMIT 1) AS draft_status,
       EXISTS (SELECT 1 FROM public.review_classifications c WHERE c.review_id = r.id AND c.verified_at IS NOT NULL) AS qa_done
FROM public.raw_reviews r
LEFT JOIN public.amazon_skus k ON k.tenant_id = r.tenant_id AND k.asin = r.asin;
GRANT SELECT ON public.v_review_triage TO authenticated;

CREATE OR REPLACE VIEW public.v_review_topic_summary WITH (security_invoker = true) AS
SELECT c.tenant_id, r.asin, c.topic_code, coalesce(t.label, c.topic_code) AS label, coalesce(t.type, 'other') AS type,
       count(*) AS reviews,
       count(*) FILTER (WHERE coalesce(r.reviewed_at, r.created_at) > now() - interval '30 days') AS reviews_30d,
       count(*) FILTER (WHERE coalesce(r.reviewed_at, r.created_at) > now() - interval '90 days') AS reviews_90d,
       round(avg(r.rating), 2) AS avg_rating,
       max(c.severity) AS max_severity,
       max(coalesce(r.reviewed_at, r.created_at)) AS last_seen
FROM public.review_classifications c
JOIN public.raw_reviews r ON r.id = c.review_id
LEFT JOIN public.review_topics t ON t.tenant_id = c.tenant_id AND t.code = c.topic_code
GROUP BY c.tenant_id, r.asin, c.topic_code, t.label, t.type;
GRANT SELECT ON public.v_review_topic_summary TO authenticated;

CREATE OR REPLACE VIEW public.v_classification_precision WITH (security_invoker = true) AS
SELECT tenant_id, topic_code,
       count(*) AS total,
       count(*) FILTER (WHERE verified_at IS NOT NULL) AS verified,
       count(*) FILTER (WHERE verified_ok) AS correct,
       CASE WHEN count(*) FILTER (WHERE verified_at IS NOT NULL) > 0
            THEN round(100.0 * count(*) FILTER (WHERE verified_ok) / count(*) FILTER (WHERE verified_at IS NOT NULL), 0) END AS precision_pct
FROM public.review_classifications WHERE method <> 'human'
GROUP BY tenant_id, topic_code;
GRANT SELECT ON public.v_classification_precision TO authenticated;

-- ------------------------------------------------------------
-- 7. Rule: cụm review tiêu cực (≥3 review sao ≤3 cùng chủ đề lỗi trong 30 ngày) → ngoại lệ P2 (chỉ cảnh báo)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_review_rules(t UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD; n INT := 0; pol public.policy_register%ROWTYPE;
BEGIN
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = t;
  FOR r IN SELECT s.asin, s.topic_code, s.label, s.reviews_30d, s.avg_rating, k.id AS sku_id
           FROM public.v_review_topic_summary s JOIN public.amazon_skus k ON k.tenant_id = s.tenant_id AND k.asin = s.asin
           WHERE s.tenant_id = t AND s.type IN ('defect','logistics','content') AND s.reviews_30d >= 3 AND s.avg_rating <= 3
             AND COALESCE((pol.rule_toggles->>'REVIEW_CLUSTER')::boolean, TRUE) LOOP
    IF public._open_exception(t, r.sku_id, r.asin, 'REVIEW_CLUSTER', 'P2',
         format('%s review sao thấp trong 30 ngày cùng chủ đề "%s" (TB %s★) – cần ticket VOC', r.reviews_30d, r.label, r.avg_rating),
         jsonb_build_object('topic', r.topic_code, 'reviews_30d', r.reviews_30d, 'avg_rating', r.avg_rating), COALESCE(pol.cooldown_days, 7)) THEN n := n + 1; END IF;
  END LOOP;
  -- tự đóng khi cụm tan
  UPDATE public.exceptions e SET resolved = TRUE, resolved_at = now(), auto_resolved = TRUE, resolution_note = 'Cụm review không còn'
   WHERE e.tenant_id = t AND e.rule_code = 'REVIEW_CLUSTER' AND NOT e.resolved
     AND NOT EXISTS (SELECT 1 FROM public.v_review_topic_summary s WHERE s.tenant_id = t AND s.asin = e.asin AND s.topic_code = e.context->>'topic' AND s.reviews_30d >= 3 AND s.avg_rating <= 3);
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.run_review_rules(UUID) TO authenticated;

-- gắn vào run_rules_all (cron 03:30)
CREATE OR REPLACE FUNCTION public.run_rules_all()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.tenants LOOP
    PERFORM public.run_rules(r.id, 'cron');
    PERFORM public.run_review_rules(r.id);
  END LOOP;
END; $$;

-- ------------------------------------------------------------
-- 8. RLS
-- ------------------------------------------------------------
ALTER TABLE public.review_topics          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_classifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voc_tickets            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.response_drafts        ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname='public' AND tablename IN ('review_topics','review_classifications','voc_tickets','response_drafts')
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP;
END $$;
CREATE POLICY rt_select ON public.review_topics FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY rt_write  ON public.review_topics FOR ALL    TO authenticated USING (public.has_role(tenant_id, ARRAY['owner'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner']));
CREATE POLICY rc_select ON public.review_classifications FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY rc_write  ON public.review_classifications FOR ALL    TO authenticated USING (public.has_role(tenant_id, ARRAY['owner','operator'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY voc_select ON public.voc_tickets FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY voc_write  ON public.voc_tickets FOR ALL    TO authenticated USING (public.has_role(tenant_id, ARRAY['owner','operator'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY rd_select ON public.response_drafts FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY rd_write  ON public.response_drafts FOR ALL    TO authenticated USING (public.has_role(tenant_id, ARRAY['owner','operator'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));

-- Audit cho bảng mới (dùng trigger audit sẵn có của 004 nếu tồn tại)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'write_audit_log') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_audit_voc ON public.voc_tickets';
    EXECUTE 'CREATE TRIGGER trg_audit_voc AFTER INSERT OR UPDATE OR DELETE ON public.voc_tickets FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_audit_drafts ON public.response_drafts';
    EXECUTE 'CREATE TRIGGER trg_audit_drafts AFTER INSERT OR UPDATE OR DELETE ON public.response_drafts FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()';
  END IF;
END $$;

-- Phân loại review hiện có + chạy rule cụm
SELECT public.classify_reviews(id, TRUE) FROM public.tenants;
SELECT public.run_review_rules(id) FROM public.tenants;
