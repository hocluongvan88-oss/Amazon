-- ============================================================
-- 013 — P0‑2/P0‑3: Content & Listing Intelligence Studio (nền)
--   Product Facts (+ evidence, connector‑agnostic)  ·  content_versions
--   Compliance Gate  ·  approval state machine  ·  publish record
--   version history / rollback  ·  đo CVR trước/sau (content_impact)
-- Chạy SAU 012. Idempotent. Không có write‑back Amazon; publish = ghi nhận thủ công.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Product Facts — nguồn sự thật cho mọi claim
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_facts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku_id        UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  key           TEXT NOT NULL,                       -- 'material', 'capacity_ml', 'certification', 'warranty_months', ...
  value         TEXT NOT NULL,
  unit          TEXT,
  -- Nguồn (connector‑agnostic): manual | document | csv | sp_api | lab_test | supplier | brand_guideline
  source_type   TEXT NOT NULL CHECK (source_type IN ('manual','document','csv','sp_api','lab_test','supplier','brand_guideline')),
  source_ref    TEXT,                                -- URL / tên file / mã chứng nhận / job id
  status        TEXT NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','verified','rejected','retired')),
  proposed_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  verified_by   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  verified_at   TIMESTAMPTZ,
  reject_reason TEXT,
  note          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_facts_sku ON public.product_facts(sku_id, status);
-- Mỗi key chỉ có 1 fact verified tại một thời điểm
CREATE UNIQUE INDEX IF NOT EXISTS uq_facts_verified ON public.product_facts(sku_id, key) WHERE status = 'verified';

CREATE OR REPLACE FUNCTION public.product_fact_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid();
BEGIN
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' THEN
    IF uid IS NOT NULL AND NOT public.has_permission(NEW.tenant_id, 'facts.propose') THEN RAISE EXCEPTION 'Không đủ quyền đề xuất fact (facts.propose)'; END IF;
    NEW.proposed_by := COALESCE(NEW.proposed_by, uid);
    IF NEW.status <> 'proposed' THEN NEW.status := 'proposed'; END IF;  -- luôn qua bước duyệt
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status IN ('verified','rejected','retired') THEN
      IF uid IS NOT NULL AND NOT public.has_permission(NEW.tenant_id, 'facts.approve') THEN RAISE EXCEPTION 'Không đủ quyền duyệt fact (facts.approve)'; END IF;
      -- SoD: người đề xuất không tự verify
      IF NEW.status = 'verified' AND uid IS NOT NULL AND uid = OLD.proposed_by AND NOT public.has_permission(NEW.tenant_id, 'policy.override') THEN
        RAISE EXCEPTION 'Người đề xuất không tự xác minh fact';
      END IF;
      IF NEW.status = 'verified' AND COALESCE(trim(NEW.source_ref), '') = '' AND NEW.source_type <> 'manual' THEN
        RAISE EXCEPTION 'Fact cần source_ref (bằng chứng) trước khi xác minh';
      END IF;
      IF NEW.status = 'rejected' AND COALESCE(trim(NEW.reject_reason), '') = '' THEN RAISE EXCEPTION 'Từ chối fact phải có lý do'; END IF;
      IF NEW.status = 'verified' THEN
        NEW.verified_by := uid; NEW.verified_at := now();
        -- retire fact verified cũ cùng key
        UPDATE public.product_facts SET status = 'retired', updated_at = now() WHERE sku_id = NEW.sku_id AND key = NEW.key AND status = 'verified' AND id <> NEW.id;
      END IF;
    END IF;
  ELSIF OLD.status = 'verified' AND (NEW.value IS DISTINCT FROM OLD.value OR NEW.unit IS DISTINCT FROM OLD.unit OR NEW.key IS DISTINCT FROM OLD.key) THEN
    RAISE EXCEPTION 'Không sửa fact đã xác minh — tạo fact mới để thay thế';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_product_facts_guard ON public.product_facts;
CREATE TRIGGER trg_product_facts_guard BEFORE INSERT OR UPDATE ON public.product_facts FOR EACH ROW EXECUTE FUNCTION public.product_fact_guard();

-- ------------------------------------------------------------
-- 2. Content versions — listing & A+
-- ------------------------------------------------------------
-- kind: title | bullets | description | backend_keywords | aplus
-- body (jsonb):
--   title            {"text": "..."}
--   bullets          {"items": ["...", ...]}
--   description      {"text": "..."}
--   backend_keywords {"text": "..."}
--   aplus            {"modules": [{"type":"standard_image_text","header":"..","body":"..","image_brief":".."}, ...]}
-- claims (jsonb): [{"text":"BPA‑free","fact_id":"uuid"|null}] — mọi claim phải trỏ về fact verified
CREATE TABLE IF NOT EXISTS public.content_versions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku_id           UUID NOT NULL REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL CHECK (kind IN ('title','bullets','description','backend_keywords','aplus')),
  version          INT  NOT NULL,
  parent_id        UUID REFERENCES public.content_versions(id) ON DELETE SET NULL,
  body             JSONB NOT NULL,
  claims           JSONB NOT NULL DEFAULT '[]'::jsonb,
  brief            TEXT,                             -- content brief / lý do thay đổi
  origin           TEXT NOT NULL DEFAULT 'human' CHECK (origin IN ('human','ai_draft','import')),
  evidence         JSONB NOT NULL DEFAULT '{}'::jsonb, -- {"review_topics":[..],"keywords":[..],"opportunity":".."}
  status           TEXT NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','qa_review','qa_passed','qa_blocked','awaiting_brand_approval','approved','published','rejected','rolled_back','superseded')),
  compliance       JSONB,                            -- kết quả gate gần nhất
  compliance_override_reason TEXT,
  created_by       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  qa_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL,  qa_at TIMESTAMPTZ,
  brand_by         UUID REFERENCES auth.users(id) ON DELETE SET NULL,  brand_at TIMESTAMPTZ,
  published_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,  published_at TIMESTAMPTZ,
  publish_channel  TEXT,                             -- 'seller_central_manual' | 'sp_api' (P2)
  publish_ref      TEXT,                             -- submission id / ghi chú
  reject_reason    TEXT,
  rollback_reason  TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (sku_id, kind, version)
);
CREATE INDEX IF NOT EXISTS idx_cv_tenant_status ON public.content_versions(tenant_id, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_cv_sku_kind ON public.content_versions(sku_id, kind, version DESC);
-- Chỉ 1 bản published/kind/sku
CREATE UNIQUE INDEX IF NOT EXISTS uq_cv_published ON public.content_versions(sku_id, kind) WHERE status = 'published';

-- Từ cấm / claim nhạy cảm theo tenant (owner/content_qa sửa); seed mặc định theo policy Amazon
CREATE TABLE IF NOT EXISTS public.content_banned_terms (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE,  -- NULL = toàn cục
  term      TEXT NOT NULL,
  severity  TEXT NOT NULL DEFAULT 'block' CHECK (severity IN ('block','warn')),
  reason    TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_banned_terms ON public.content_banned_terms(COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(term));
INSERT INTO public.content_banned_terms (tenant_id, term, severity, reason) VALUES
  (NULL, 'best seller',        'block', 'Amazon cấm claim xếp hạng trong listing'),
  (NULL, '#1',                 'block', 'Claim xếp hạng'),
  (NULL, 'free shipping',      'block', 'Không đưa thông tin vận chuyển/khuyến mãi vào listing'),
  (NULL, 'sale',               'warn',  'Thông tin khuyến mãi'),
  (NULL, 'guarantee',          'warn',  'Bảo đảm cần có chính sách rõ ràng'),
  (NULL, 'cure',               'block', 'Health claim'),
  (NULL, 'treat',              'warn',  'Health claim'),
  (NULL, 'fda approved',       'block', 'Health/regulatory claim'),
  (NULL, 'antibacterial',      'block', 'Pesticide claim – cần EPA'),
  (NULL, 'antimicrobial',      'block', 'Pesticide claim – cần EPA'),
  (NULL, 'eco-friendly',       'warn',  'Environmental claim cần chứng minh (FTC Green Guides)'),
  (NULL, 'biodegradable',      'warn',  'Environmental claim cần chứng minh'),
  (NULL, 'lifetime warranty',  'warn',  'Warranty claim phải có fact'),
  (NULL, 'amazon',             'warn',  'Không dùng tên Amazon trong nội dung')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- 3. Compliance Gate
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_content_compliance(p_tenant UUID, p_sku UUID, p_kind TEXT, p_body JSONB, p_claims JSONB)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  txt TEXT; issues JSONB := '[]'::jsonb; blocks INT := 0; warns INT := 0; r RECORD; c JSONB; i INT; n INT; item TEXT;
  title_max INT := 200; bullet_max INT := 500; desc_max INT := 2000; backend_max_bytes INT := 249;
BEGIN
  -- ghép text theo kind
  txt := CASE p_kind
    WHEN 'title' THEN p_body->>'text'
    WHEN 'description' THEN p_body->>'text'
    WHEN 'backend_keywords' THEN p_body->>'text'
    WHEN 'bullets' THEN (SELECT string_agg(x, E'\n') FROM jsonb_array_elements_text(COALESCE(p_body->'items','[]'::jsonb)) x)
    WHEN 'aplus' THEN (SELECT string_agg(COALESCE(m->>'header','') || ' ' || COALESCE(m->>'body',''), E'\n') FROM jsonb_array_elements(COALESCE(p_body->'modules','[]'::jsonb)) m)
  END;
  txt := COALESCE(txt, '');

  -- (a) độ dài / cấu trúc
  IF length(trim(txt)) = 0 THEN issues := issues || jsonb_build_object('code','empty','severity','block','msg','Nội dung trống'); blocks := blocks + 1; END IF;
  IF p_kind = 'title' THEN
    IF length(txt) > title_max THEN issues := issues || jsonb_build_object('code','title_len','severity','block','msg',format('Title %s ký tự > %s', length(txt), title_max)); blocks := blocks + 1; END IF;
    IF txt ~ '[!$?_{}^¬¦]' THEN issues := issues || jsonb_build_object('code','title_chars','severity','block','msg','Title chứa ký tự không cho phép (! $ ? _ { } ^ ¬ ¦)'); blocks := blocks + 1; END IF;
    IF txt = upper(txt) AND txt ~ '[A-Z]' THEN issues := issues || jsonb_build_object('code','title_caps','severity','block','msg','Title toàn chữ hoa'); blocks := blocks + 1; END IF;
  ELSIF p_kind = 'bullets' THEN
    n := jsonb_array_length(COALESCE(p_body->'items','[]'::jsonb));
    IF n = 0 OR n > 5 THEN issues := issues || jsonb_build_object('code','bullet_count','severity','block','msg',format('Cần 1–5 bullet (hiện %s)', n)); blocks := blocks + 1; END IF;
    FOR i IN 0..GREATEST(n-1,0) LOOP
      item := p_body->'items'->>i;
      IF item IS NOT NULL AND length(item) > bullet_max THEN issues := issues || jsonb_build_object('code','bullet_len','severity','block','msg',format('Bullet %s dài %s > %s', i+1, length(item), bullet_max)); blocks := blocks + 1; END IF;
    END LOOP;
  ELSIF p_kind = 'description' THEN
    IF length(txt) > desc_max THEN issues := issues || jsonb_build_object('code','desc_len','severity','block','msg',format('Mô tả %s ký tự > %s', length(txt), desc_max)); blocks := blocks + 1; END IF;
    IF txt ~* '<(?!/?(br|b|i|p)\y)[a-z]+' THEN issues := issues || jsonb_build_object('code','desc_html','severity','warn','msg','HTML ngoài <br>/<b>/<i>/<p> có thể bị lọc'); warns := warns + 1; END IF;
  ELSIF p_kind = 'backend_keywords' THEN
    IF octet_length(txt) > backend_max_bytes THEN issues := issues || jsonb_build_object('code','backend_bytes','severity','block','msg',format('Backend %s bytes > %s', octet_length(txt), backend_max_bytes)); blocks := blocks + 1; END IF;
    IF txt ~ ',' THEN issues := issues || jsonb_build_object('code','backend_commas','severity','warn','msg','Không cần dấu phẩy trong backend keywords'); warns := warns + 1; END IF;
  ELSIF p_kind = 'aplus' THEN
    n := jsonb_array_length(COALESCE(p_body->'modules','[]'::jsonb));
    IF n = 0 OR n > 7 THEN issues := issues || jsonb_build_object('code','aplus_modules','severity','block','msg',format('A+ cần 1–7 module (hiện %s)', n)); blocks := blocks + 1; END IF;
    FOR i IN 0..GREATEST(n-1,0) LOOP
      IF COALESCE(p_body->'modules'->i->>'type','') NOT IN ('standard_image_text','standard_text','comparison_chart','four_image_text','image_header_text','tech_specs') THEN
        issues := issues || jsonb_build_object('code','aplus_type','severity','block','msg',format('Module %s có type không hợp lệ', i+1)); blocks := blocks + 1;
      END IF;
    END LOOP;
  END IF;

  -- (b) từ cấm
  FOR r IN SELECT term, severity, reason FROM public.content_banned_terms WHERE tenant_id IS NULL OR tenant_id = p_tenant LOOP
    IF txt ~* ('\m' || regexp_replace(r.term, '([.*+?^${}()|\[\]\\#])', '\\\1', 'g') || '\M') THEN
      issues := issues || jsonb_build_object('code','banned_term','severity',r.severity,'msg',format('"%s": %s', r.term, r.reason));
      IF r.severity = 'block' THEN blocks := blocks + 1; ELSE warns := warns + 1; END IF;
    END IF;
  END LOOP;

  -- (c) claim phải có fact verified
  FOR c IN SELECT * FROM jsonb_array_elements(COALESCE(p_claims,'[]'::jsonb)) LOOP
    IF (c->>'fact_id') IS NULL OR NOT EXISTS (SELECT 1 FROM public.product_facts f WHERE f.id = (c->>'fact_id')::uuid AND f.sku_id = p_sku AND f.status = 'verified') THEN
      issues := issues || jsonb_build_object('code','claim_no_fact','severity','block','msg',format('Claim "%s" không có fact đã xác minh', c->>'text')); blocks := blocks + 1;
    END IF;
  END LOOP;
  -- (d) số/đơn vị xuất hiện trong text mà không khai claim → cảnh báo
  IF p_kind <> 'backend_keywords' AND txt ~ '\d+\s?(ml|oz|lb|kg|g|cm|inch|in|mm|%|years?|months?|hours?)\M' AND jsonb_array_length(COALESCE(p_claims,'[]'::jsonb)) = 0 THEN
    issues := issues || jsonb_build_object('code','unclaimed_numbers','severity','warn','msg','Có số liệu/đơn vị trong nội dung nhưng chưa khai báo claim → fact'); warns := warns + 1;
  END IF;
  -- (e) keyword stuffing: 1 từ ≥ 5 chữ lặp > 4 lần trong title/bullets
  IF p_kind IN ('title','bullets') THEN
    SELECT count(*) INTO n FROM (SELECT w FROM regexp_split_to_table(lower(txt), '\W+') w WHERE length(w) >= 5 GROUP BY w HAVING count(*) > 4) s;
    IF n > 0 THEN issues := issues || jsonb_build_object('code','stuffing','severity','warn','msg','Có từ lặp > 4 lần (keyword stuffing)'); warns := warns + 1; END IF;
  END IF;

  RETURN jsonb_build_object('ok', blocks = 0, 'blocks', blocks, 'warns', warns, 'issues', issues, 'checked_at', now());
END; $$;
GRANT EXECUTE ON FUNCTION public.check_content_compliance(UUID, UUID, TEXT, JSONB, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 4. State machine + permission + SoD
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.content_version_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid(); has_brand BOOLEAN;
BEGIN
  NEW.updated_at := now();

  IF TG_OP = 'INSERT' THEN
    IF uid IS NOT NULL AND NOT public.has_permission(NEW.tenant_id, 'content.draft') THEN RAISE EXCEPTION 'Không đủ quyền tạo draft (content.draft)'; END IF;
    NEW.created_by := COALESCE(NEW.created_by, uid);
    NEW.status := 'draft';
    SELECT COALESCE(MAX(version),0)+1 INTO NEW.version FROM public.content_versions WHERE sku_id = NEW.sku_id AND kind = NEW.kind;
    NEW.compliance := public.check_content_compliance(NEW.tenant_id, NEW.sku_id, NEW.kind, NEW.body, NEW.claims);
    RETURN NEW;
  END IF;

  -- Sửa nội dung: chỉ khi draft / qa_blocked / rejected; chạy lại gate
  IF NEW.body IS DISTINCT FROM OLD.body OR NEW.claims IS DISTINCT FROM OLD.claims THEN
    IF OLD.status NOT IN ('draft','qa_blocked','rejected') THEN RAISE EXCEPTION 'Không sửa nội dung ở trạng thái % — tạo version mới', OLD.status; END IF;
    IF uid IS NOT NULL AND NOT public.has_permission(NEW.tenant_id, 'content.draft') THEN RAISE EXCEPTION 'Không đủ quyền sửa draft'; END IF;
    NEW.compliance := public.check_content_compliance(NEW.tenant_id, NEW.sku_id, NEW.kind, NEW.body, NEW.claims);
    NEW.compliance_override_reason := NULL;
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN NEW.status := 'draft'; END IF;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
      (OLD.status IN ('draft','qa_blocked','rejected') AND NEW.status = 'qa_review') OR
      (OLD.status = 'qa_review' AND NEW.status IN ('qa_passed','qa_blocked','rejected')) OR
      (OLD.status = 'qa_passed' AND NEW.status IN ('awaiting_brand_approval','rejected')) OR
      (OLD.status = 'awaiting_brand_approval' AND NEW.status IN ('approved','rejected')) OR
      (OLD.status = 'approved' AND NEW.status IN ('published','rejected')) OR
      (OLD.status = 'published' AND NEW.status IN ('rolled_back','superseded')) OR
      (OLD.status = 'qa_blocked' AND NEW.status = 'draft') OR
      (OLD.status = 'rejected' AND NEW.status = 'draft')
    ) THEN RAISE EXCEPTION 'Chuyển trạng thái content % → % không hợp lệ', OLD.status, NEW.status; END IF;

    IF uid IS NOT NULL THEN
      CASE NEW.status
        WHEN 'qa_review' THEN
          IF NOT public.has_permission(NEW.tenant_id, 'content.draft') THEN RAISE EXCEPTION 'Không đủ quyền gửi QA'; END IF;
          -- gate tự động: block → không cho gửi
          NEW.compliance := public.check_content_compliance(NEW.tenant_id, NEW.sku_id, NEW.kind, NEW.body, NEW.claims);
          IF NOT (NEW.compliance->>'ok')::boolean THEN
            IF COALESCE(trim(NEW.compliance_override_reason),'') = '' OR NOT public.has_permission(NEW.tenant_id, 'policy.override') THEN
              RAISE EXCEPTION 'Compliance gate chặn (% lỗi). Sửa nội dung hoặc override có lý do với quyền policy.override', NEW.compliance->>'blocks';
            END IF;
          END IF;
        WHEN 'qa_passed', 'qa_blocked' THEN
          IF NOT public.has_permission(NEW.tenant_id, 'content.qa_approve') THEN RAISE EXCEPTION 'Không đủ quyền QA (content.qa_approve)'; END IF;
          IF uid = OLD.created_by AND NOT public.has_permission(NEW.tenant_id, 'policy.override') THEN RAISE EXCEPTION 'Người soạn không tự QA'; END IF;
          IF NEW.status = 'qa_blocked' AND COALESCE(trim(NEW.reject_reason),'') = '' THEN RAISE EXCEPTION 'QA block phải có lý do'; END IF;
          NEW.qa_by := uid; NEW.qa_at := now();
        WHEN 'awaiting_brand_approval' THEN
          IF NOT (public.has_permission(NEW.tenant_id, 'content.qa_approve') OR public.has_permission(NEW.tenant_id, 'content.draft')) THEN RAISE EXCEPTION 'Không đủ quyền'; END IF;
        WHEN 'approved' THEN
          IF NOT public.has_permission(NEW.tenant_id, 'content.brand_approve') THEN RAISE EXCEPTION 'Chỉ Brand Approver (hoặc người được brand uỷ quyền) duyệt cuối content'; END IF;
          IF uid IN (OLD.created_by, OLD.qa_by) AND NOT public.has_permission(NEW.tenant_id, 'policy.override') THEN RAISE EXCEPTION 'Người soạn/QA không tự duyệt cuối'; END IF;
          NEW.brand_by := uid; NEW.brand_at := now();
        WHEN 'published' THEN
          IF NOT public.has_permission(NEW.tenant_id, 'content.publish') THEN RAISE EXCEPTION 'Không đủ quyền ghi nhận publish (content.publish)'; END IF;
          IF OLD.brand_by IS NULL THEN RAISE EXCEPTION 'Chưa có brand approval'; END IF;
          NEW.published_by := uid; NEW.published_at := now();
          NEW.publish_channel := COALESCE(NEW.publish_channel, 'seller_central_manual');
          -- bản published cũ → superseded (giữ lịch sử)
          UPDATE public.content_versions SET status = 'superseded', updated_at = now() WHERE sku_id = NEW.sku_id AND kind = NEW.kind AND status = 'published' AND id <> NEW.id;
        WHEN 'rolled_back' THEN
          IF NOT public.has_permission(NEW.tenant_id, 'content.publish') THEN RAISE EXCEPTION 'Không đủ quyền rollback'; END IF;
          IF COALESCE(trim(NEW.rollback_reason),'') = '' THEN RAISE EXCEPTION 'Rollback phải có lý do'; END IF;
        WHEN 'rejected' THEN
          IF COALESCE(trim(NEW.reject_reason),'') = '' THEN RAISE EXCEPTION 'Từ chối phải có lý do'; END IF;
        WHEN 'draft' THEN
          NEW.qa_by := NULL; NEW.qa_at := NULL; NEW.brand_by := NULL; NEW.brand_at := NULL; NEW.reject_reason := NULL;
        ELSE NULL;
      END CASE;
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_content_versions_guard ON public.content_versions;
CREATE TRIGGER trg_content_versions_guard BEFORE INSERT OR UPDATE ON public.content_versions FOR EACH ROW EXECUTE FUNCTION public.content_version_guard();

-- Nếu tenant chưa có ai giữ content.brand_approve → content dừng ở awaiting_brand_approval (không có bước nào tự publish)
CREATE OR REPLACE VIEW public.v_content_readiness WITH (security_invoker = true) AS
SELECT t.id AS tenant_id,
       EXISTS (SELECT 1 FROM public.tenant_members m JOIN public.role_permissions rp ON rp.role = m.role
               WHERE m.tenant_id = t.id AND rp.permission_key = 'content.brand_approve') AS has_brand_approver,
       EXISTS (SELECT 1 FROM public.permission_delegations d WHERE d.tenant_id = t.id AND d.permission_key = 'content.brand_approve'
               AND d.revoked_at IS NULL AND now() BETWEEN d.starts_at AND d.expires_at) AS has_delegated_brand_approver,
       (SELECT count(*) FROM public.content_versions c WHERE c.tenant_id = t.id AND c.status = 'awaiting_brand_approval') AS awaiting_brand,
       (SELECT count(*) FROM public.content_versions c WHERE c.tenant_id = t.id AND c.status = 'qa_review') AS awaiting_qa,
       (SELECT count(*) FROM public.content_versions c WHERE c.tenant_id = t.id AND c.status = 'approved') AS ready_to_publish
FROM public.tenants t WHERE t.id IN (SELECT public.my_tenant_ids());

-- ------------------------------------------------------------
-- 5. Listing audit — cơ hội content theo SKU (evidence từ facts/reviews/CVR)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_listing_audit WITH (security_invoker = true) AS
WITH pub AS (
  SELECT sku_id, kind FROM public.content_versions WHERE status = 'published'
), cvr AS (
  SELECT sku_id,
         SUM(units)::numeric / NULLIF(SUM(sessions),0) AS cvr_30d,
         SUM(sessions) AS sessions_30d
  FROM public.sku_daily_snapshots WHERE date > CURRENT_DATE - 30 GROUP BY sku_id
), med AS (
  SELECT tenant_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY c.cvr_30d) AS cvr_median
  FROM cvr c JOIN public.amazon_skus k ON k.id = c.sku_id GROUP BY tenant_id
), neg AS (
  SELECT r.tenant_id, r.asin, count(*) AS neg_reviews_90d
  FROM public.raw_reviews r WHERE r.rating <= 3 AND COALESCE(r.reviewed_at, r.created_at) > now() - interval '90 days' GROUP BY r.tenant_id, r.asin
), facts AS (
  SELECT sku_id, count(*) FILTER (WHERE status='verified') AS facts_verified, count(*) FILTER (WHERE status='proposed') AS facts_proposed
  FROM public.product_facts GROUP BY sku_id
)
SELECT k.tenant_id, k.id AS sku_id, k.asin, k.title,
       COALESCE(f.facts_verified,0) AS facts_verified, COALESCE(f.facts_proposed,0) AS facts_proposed,
       EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='title')   AS has_title,
       EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='bullets') AS has_bullets,
       EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='description') AS has_description,
       EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='backend_keywords') AS has_backend,
       EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='aplus')   AS has_aplus,
       c.cvr_30d, c.sessions_30d, m.cvr_median,
       COALESCE(n.neg_reviews_90d,0) AS neg_reviews_90d,
       -- điểm cơ hội 0–100
       LEAST(100,
         (CASE WHEN COALESCE(f.facts_verified,0) = 0 THEN 25 ELSE 0 END) +
         (CASE WHEN NOT EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='aplus') THEN 20 ELSE 0 END) +
         (CASE WHEN NOT EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='bullets') THEN 15 ELSE 0 END) +
         (CASE WHEN c.cvr_30d IS NOT NULL AND m.cvr_median IS NOT NULL AND c.cvr_30d < m.cvr_median * 0.8 THEN 25 ELSE 0 END) +
         (CASE WHEN COALESCE(n.neg_reviews_90d,0) >= 3 THEN 15 ELSE 0 END)
       ) AS opportunity_score,
       ARRAY_REMOVE(ARRAY[
         CASE WHEN COALESCE(f.facts_verified,0) = 0 THEN 'Chưa có Product Fact đã xác minh' END,
         CASE WHEN NOT EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='aplus') THEN 'Chưa có A+ được ghi nhận' END,
         CASE WHEN NOT EXISTS (SELECT 1 FROM pub WHERE pub.sku_id=k.id AND kind='bullets') THEN 'Chưa quản lý bullets' END,
         CASE WHEN c.cvr_30d IS NOT NULL AND m.cvr_median IS NOT NULL AND c.cvr_30d < m.cvr_median * 0.8 THEN format('CVR %s%% dưới median %s%%', round(c.cvr_30d*100,1), round(m.cvr_median*100,1)) END,
         CASE WHEN COALESCE(n.neg_reviews_90d,0) >= 3 THEN format('%s review ≤3★ trong 90 ngày – cần giải thích trong listing', n.neg_reviews_90d) END
       ], NULL) AS reasons
FROM public.amazon_skus k
LEFT JOIN facts f ON f.sku_id = k.id
LEFT JOIN cvr c ON c.sku_id = k.id
LEFT JOIN med m ON m.tenant_id = k.tenant_id
LEFT JOIN neg n ON n.tenant_id = k.tenant_id AND n.asin = k.asin
WHERE k.tenant_id IN (SELECT public.my_tenant_ids());

-- ------------------------------------------------------------
-- 6. Đo CVR/CTR trước–sau publish (kèm thay đổi đồng thời & confidence)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.content_impact(p_version UUID, p_days INT DEFAULT 14)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.content_versions%ROWTYPE; b RECORD; a RECORD; conc JSONB := '[]'::jsonb; price_chg INT; ads_chg NUMERIC; oos INT; other_pub INT; conf TEXT; note TEXT;
BEGIN
  SELECT * INTO v FROM public.content_versions WHERE id = p_version;
  IF v.id IS NULL OR v.published_at IS NULL THEN RETURN jsonb_build_object('ok', false, 'note', 'Chưa publish'); END IF;
  IF auth.uid() IS NOT NULL AND NOT (v.tenant_id IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;

  SELECT COALESCE(SUM(sessions),0) AS sessions, COALESCE(SUM(units),0) AS units, COALESCE(SUM(page_views),0) AS pv, COUNT(*) AS days,
         AVG(price) AS price, COALESCE(SUM(ad_spend),0) AS ad_spend
    INTO b FROM public.sku_daily_snapshots WHERE sku_id = v.sku_id AND date >= (v.published_at::date - p_days) AND date < v.published_at::date;
  SELECT COALESCE(SUM(sessions),0) AS sessions, COALESCE(SUM(units),0) AS units, COALESCE(SUM(page_views),0) AS pv, COUNT(*) AS days,
         AVG(price) AS price, COALESCE(SUM(ad_spend),0) AS ad_spend
    INTO a FROM public.sku_daily_snapshots WHERE sku_id = v.sku_id AND date > v.published_at::date AND date <= (v.published_at::date + p_days);

  -- thay đổi đồng thời
  SELECT count(*) INTO price_chg FROM public.actions WHERE sku_id = v.sku_id AND action_type = 'price_update' AND mode <> 'dry_run' AND status = 'succeeded'
    AND finished_at BETWEEN v.published_at - make_interval(days => p_days) AND v.published_at + make_interval(days => p_days);
  IF price_chg > 0 THEN conc := conc || to_jsonb(format('%s thay đổi giá trong cửa sổ', price_chg)); END IF;
  IF b.price IS NOT NULL AND a.price IS NOT NULL AND abs(a.price - b.price) / NULLIF(b.price,0) > 0.02 THEN conc := conc || to_jsonb(format('Giá TB %s → %s', round(b.price,2), round(a.price,2))); END IF;
  ads_chg := CASE WHEN b.ad_spend > 0 THEN (a.ad_spend - b.ad_spend) / b.ad_spend ELSE NULL END;
  IF ads_chg IS NOT NULL AND abs(ads_chg) > 0.2 THEN conc := conc || to_jsonb(format('Chi phí ads %s%%', round(ads_chg*100))); END IF;
  SELECT count(*) INTO oos FROM public.sku_daily_snapshots WHERE sku_id = v.sku_id AND inventory_qty = 0 AND date BETWEEN (v.published_at::date - p_days) AND (v.published_at::date + p_days);
  IF oos > 0 THEN conc := conc || to_jsonb(format('%s ngày hết hàng trong cửa sổ', oos)); END IF;
  SELECT count(*) INTO other_pub FROM public.content_versions WHERE sku_id = v.sku_id AND id <> v.id AND published_at BETWEEN v.published_at - make_interval(days => p_days) AND v.published_at + make_interval(days => p_days);
  IF other_pub > 0 THEN conc := conc || to_jsonb(format('%s content khác publish cùng cửa sổ', other_pub)); END IF;

  conf := CASE
    WHEN a.days < p_days OR b.days < p_days THEN 'insufficient_data'
    WHEN b.sessions < 200 OR a.sessions < 200 THEN 'low'
    WHEN jsonb_array_length(conc) > 0 THEN 'confounded'
    ELSE 'moderate' END;
  note := CASE conf
    WHEN 'insufficient_data' THEN format('Cần đủ %s ngày dữ liệu trước và sau', p_days)
    WHEN 'low' THEN 'Sessions < 200 mỗi kỳ – chưa đủ để kết luận'
    WHEN 'confounded' THEN 'Có thay đổi đồng thời – KHÔNG gán toàn bộ thay đổi cho content'
    ELSE 'Không phát hiện thay đổi đồng thời; vẫn cần đối chứng danh mục nếu có' END;

  RETURN jsonb_build_object(
    'ok', true, 'version_id', v.id, 'kind', v.kind, 'published_at', v.published_at, 'days', p_days,
    'before', jsonb_build_object('sessions', b.sessions, 'units', b.units, 'page_views', b.pv, 'days', b.days, 'cvr', CASE WHEN b.sessions > 0 THEN round(b.units::numeric / b.sessions, 4) END, 'avg_price', round(COALESCE(b.price,0),2), 'ad_spend', b.ad_spend),
    'after',  jsonb_build_object('sessions', a.sessions, 'units', a.units, 'page_views', a.pv, 'days', a.days, 'cvr', CASE WHEN a.sessions > 0 THEN round(a.units::numeric / a.sessions, 4) END, 'avg_price', round(COALESCE(a.price,0),2), 'ad_spend', a.ad_spend),
    'cvr_delta_pct', CASE WHEN b.sessions > 0 AND a.sessions > 0 AND b.units > 0 THEN round(((a.units::numeric / a.sessions) / (b.units::numeric / b.sessions) - 1) * 100, 1) END,
    'concurrent_changes', conc, 'confidence', conf, 'note', note
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.content_impact(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 7. RLS + audit
-- ------------------------------------------------------------
ALTER TABLE public.product_facts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_versions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_banned_terms ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS facts_select ON public.product_facts;  DROP POLICY IF EXISTS facts_write ON public.product_facts;
DROP POLICY IF EXISTS cv_select ON public.content_versions;  DROP POLICY IF EXISTS cv_write ON public.content_versions;
DROP POLICY IF EXISTS bt_select ON public.content_banned_terms; DROP POLICY IF EXISTS bt_write ON public.content_banned_terms;
CREATE POLICY facts_select ON public.product_facts FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY facts_write  ON public.product_facts FOR ALL TO authenticated
  USING (public.has_permission(tenant_id, 'facts.propose') OR public.has_permission(tenant_id, 'facts.approve'))
  WITH CHECK (public.has_permission(tenant_id, 'facts.propose') OR public.has_permission(tenant_id, 'facts.approve'));
CREATE POLICY cv_select ON public.content_versions FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY cv_write  ON public.content_versions FOR ALL TO authenticated
  USING (public.has_permission(tenant_id, 'content.draft') OR public.has_permission(tenant_id, 'content.qa_approve') OR public.has_permission(tenant_id, 'content.brand_approve') OR public.has_permission(tenant_id, 'content.publish'))
  WITH CHECK (public.has_permission(tenant_id, 'content.draft') OR public.has_permission(tenant_id, 'content.qa_approve') OR public.has_permission(tenant_id, 'content.brand_approve') OR public.has_permission(tenant_id, 'content.publish'));
CREATE POLICY bt_select ON public.content_banned_terms FOR SELECT TO authenticated USING (tenant_id IS NULL OR tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY bt_write  ON public.content_banned_terms FOR ALL TO authenticated
  USING (tenant_id IS NOT NULL AND public.has_permission(tenant_id, 'content.qa_approve'))
  WITH CHECK (tenant_id IS NOT NULL AND public.has_permission(tenant_id, 'content.qa_approve'));

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['product_facts','content_versions']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()', t, t);
  END LOOP;
END $$;

-- Kiểm tra nhanh
-- SELECT * FROM public.v_listing_audit ORDER BY opportunity_score DESC LIMIT 10;
