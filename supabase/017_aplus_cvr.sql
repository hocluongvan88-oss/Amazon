-- ============================================================
-- 017 — P1: A+ Template Builder + Before/After CVR view
--   aplus_templates (seed toàn cục + theo tenant)  ·  build_aplus_from_template() điền từ Product Facts đã verified
--   check_content_compliance: thêm giới hạn ký tự/module A+ (Amazon)  ·  content_cvr_series() chuỗi ngày ± N + đối chứng
-- Nguyên tắc: template KHÔNG bịa số liệu — slot {fact:key} không có fact verified → để trống + cảnh báo; claim tự gắn fact_id
-- Chạy SAU 016. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. aplus_templates
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.aplus_templates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID REFERENCES public.tenants(id) ON DELETE CASCADE,   -- NULL = toàn cục
  key         TEXT NOT NULL,
  name        TEXT NOT NULL,
  use_case    TEXT NOT NULL CHECK (use_case IN ('launch','differentiation','trust','howto','comparison')),
  description TEXT,
  -- modules: [{type, header, body, image_brief, required_facts: [key,...]}]; placeholder {fact:KEY} / {title} / {brand}
  modules     JSONB NOT NULL,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, key)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_aplus_templates_global ON public.aplus_templates(key) WHERE tenant_id IS NULL;

INSERT INTO public.aplus_templates (tenant_id, key, name, use_case, description, modules) VALUES
(NULL, 'launch_basic', 'Ra mắt cơ bản (5 module)', 'launch', 'Giới thiệu thương hiệu → lợi ích chính → thông số → cách dùng → cam kết. Phù hợp SKU mới chưa có A+.',
 '[
  {"type":"image_header_text","header":"{brand} — {title}","body":"Một câu định vị sản phẩm: giải quyết vấn đề gì cho ai. Không dùng từ tuyệt đối (best, #1).","image_brief":"Ảnh hero: sản phẩm trong bối cảnh sử dụng thật, nền sáng, không chữ chồng lên sản phẩm.","required_facts":[]},
  {"type":"standard_image_text","header":"Lợi ích chính","body":"Mô tả lợi ích số 1 dựa trên thông số: dung tích {fact:capacity}, chất liệu {fact:material}.","image_brief":"Cận cảnh chi tiết thể hiện lợi ích (vd: nắp khoá, vật liệu).","required_facts":["capacity","material"]},
  {"type":"tech_specs","header":"Thông số kỹ thuật","body":"Kích thước: {fact:dimensions}\nTrọng lượng: {fact:weight}\nChất liệu: {fact:material}\nDung tích: {fact:capacity}","image_brief":"","required_facts":["dimensions","weight","material","capacity"]},
  {"type":"four_image_text","header":"Cách sử dụng","body":"4 bước ngắn, mỗi bước ≤ 20 từ. Không hứa hẹn kết quả không kiểm chứng.","image_brief":"4 ảnh vuông cùng phong cách, mỗi ảnh một bước.","required_facts":[]},
  {"type":"standard_text","header":"Cam kết & hỗ trợ","body":"Chính sách bảo hành {fact:warranty}. Hướng dẫn liên hệ qua Amazon Buyer‑Seller Messaging (không đưa email/điện thoại ngoài Amazon).","image_brief":"","required_facts":["warranty"]}
 ]'::jsonb),
(NULL, 'differentiation', 'Khác biệt hoá (so sánh nội bộ)', 'differentiation', 'Khi review đối thủ/khách hàng nêu điểm yếu chung của ngành — nhấn điểm khác biệt có bằng chứng.',
 '[
  {"type":"image_header_text","header":"Vì sao chọn {brand}","body":"Nêu 1 vấn đề phổ biến khách gặp (từ VoC) và cách sản phẩm giải quyết, dựa trên fact.","image_brief":"Ảnh hero thể hiện điểm khác biệt.","required_facts":[]},
  {"type":"standard_image_text","header":"Điểm khác biệt 1","body":"Bằng chứng: {fact:material} · {fact:certification}","image_brief":"Ảnh chứng nhận/kết quả kiểm nghiệm (nếu có fact lab_test).","required_facts":["material","certification"]},
  {"type":"standard_image_text","header":"Điểm khác biệt 2","body":"Bằng chứng số: {fact:capacity} / {fact:weight}","image_brief":"Ảnh so sánh kích thước với vật quen thuộc.","required_facts":["capacity","weight"]},
  {"type":"comparison_chart","header":"So sánh trong dòng sản phẩm {brand}","body":"Chỉ so sánh các SKU của chính thương hiệu (Amazon không cho so sánh đối thủ). Cột: dung tích, chất liệu, bảo hành.","image_brief":"Ảnh thumbnail từng SKU.","required_facts":[]}
 ]'::jsonb),
(NULL, 'trust_quality', 'Niềm tin & chất lượng', 'trust', 'Khi VoC có topic QUALITY/DEFECT — minh bạch quy trình, chất liệu, bảo hành.',
 '[
  {"type":"standard_image_text","header":"Chất liệu & tiêu chuẩn","body":"{fact:material} · Chứng nhận: {fact:certification}. Không dùng từ \"an toàn tuyệt đối\", \"y tế\" nếu không có fact.","image_brief":"Ảnh chất liệu cận cảnh + logo chứng nhận (nếu có).","required_facts":["material","certification"]},
  {"type":"four_image_text","header":"Kiểm soát chất lượng","body":"4 bước QC thực tế tại nhà máy/đối tác. Chỉ mô tả bước đã có tài liệu.","image_brief":"4 ảnh quy trình QC (được phép công bố).","required_facts":[]},
  {"type":"standard_text","header":"Bảo hành {fact:warranty}","body":"Điều kiện bảo hành và cách yêu cầu qua Amazon.","image_brief":"","required_facts":["warranty"]},
  {"type":"tech_specs","header":"Thông số","body":"Kích thước: {fact:dimensions}\nTrọng lượng: {fact:weight}","image_brief":"","required_facts":["dimensions","weight"]}
 ]'::jsonb),
(NULL, 'howto_usage', 'Hướng dẫn sử dụng & bảo quản', 'howto', 'Khi VoC có topic SIZE/USAGE/kỳ vọng sai — giảm trả hàng do hiểu nhầm.',
 '[
  {"type":"image_header_text","header":"Đúng kích thước cho nhu cầu của bạn","body":"Kích thước thực {fact:dimensions}, dung tích {fact:capacity}. Gợi ý chọn theo tình huống dùng.","image_brief":"Ảnh sản phẩm cạnh vật tham chiếu (bàn tay, chai 500 ml).","required_facts":["dimensions","capacity"]},
  {"type":"four_image_text","header":"4 bước sử dụng","body":"Bước 1…4, ngắn gọn, có động từ.","image_brief":"4 ảnh thao tác.","required_facts":[]},
  {"type":"standard_image_text","header":"Bảo quản & vệ sinh","body":"Hướng dẫn phù hợp chất liệu {fact:material} (vd: có rửa máy được không — chỉ ghi nếu có fact).","image_brief":"Ảnh minh hoạ vệ sinh.","required_facts":["material"]},
  {"type":"standard_text","header":"Câu hỏi thường gặp","body":"3–5 câu hỏi lấy từ review/tickets VoC, trả lời dựa trên fact.","image_brief":"","required_facts":[]}
 ]'::jsonb)
ON CONFLICT (tenant_id, key) DO UPDATE SET name = EXCLUDED.name, use_case = EXCLUDED.use_case, description = EXCLUDED.description, modules = EXCLUDED.modules;

-- ------------------------------------------------------------
-- 2. build_aplus_from_template — điền placeholder từ facts verified; trả body + claims + missing
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.build_aplus_from_template(p_template UUID, p_sku UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE tpl public.aplus_templates; k public.amazon_skus; m JSONB; out_mods JSONB := '[]'::jsonb; claims JSONB := '[]'::jsonb; missing TEXT[] := '{}';
  hdr TEXT; bdy TEXT; f RECORD; fk TEXT; val TEXT; used TEXT[] := '{}'; brand TEXT;
BEGIN
  SELECT * INTO tpl FROM public.aplus_templates WHERE id = p_template AND is_active;
  IF tpl.id IS NULL THEN RAISE EXCEPTION 'Template không tồn tại'; END IF;
  SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  IF k.id IS NULL THEN RAISE EXCEPTION 'SKU không tồn tại'; END IF;
  IF auth.uid() IS NOT NULL AND NOT (k.tenant_id IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  IF tpl.tenant_id IS NOT NULL AND tpl.tenant_id <> k.tenant_id THEN RAISE EXCEPTION 'Template thuộc tenant khác'; END IF;
  brand := COALESCE((SELECT value FROM public.product_facts WHERE sku_id = p_sku AND key = 'brand' AND status = 'verified' LIMIT 1), (SELECT name FROM public.tenants WHERE id = k.tenant_id));

  FOR m IN SELECT * FROM jsonb_array_elements(tpl.modules) LOOP
    hdr := COALESCE(m->>'header',''); bdy := COALESCE(m->>'body','');
    hdr := replace(replace(hdr, '{title}', COALESCE(k.title,'')), '{brand}', COALESCE(brand,''));
    bdy := replace(replace(bdy, '{title}', COALESCE(k.title,'')), '{brand}', COALESCE(brand,''));
    -- thay {fact:key}
    FOR fk IN SELECT DISTINCT x[1] FROM regexp_matches(hdr || ' ' || bdy, '\{fact:([a-z0-9_]+)\}', 'g') AS x LOOP
      SELECT id, value, unit INTO f FROM public.product_facts WHERE sku_id = p_sku AND key = fk AND status = 'verified' ORDER BY updated_at DESC LIMIT 1;
      IF f.id IS NULL THEN
        missing := array_append(missing, fk);
        hdr := replace(hdr, '{fact:' || fk || '}', '[' || fk || ': CHƯA CÓ FACT]');
        bdy := replace(bdy, '{fact:' || fk || '}', '[' || fk || ': CHƯA CÓ FACT]');
      ELSE
        val := f.value || COALESCE(' ' || f.unit, '');
        hdr := replace(hdr, '{fact:' || fk || '}', val);
        bdy := replace(bdy, '{fact:' || fk || '}', val);
        IF NOT (fk = ANY(used)) THEN
          claims := claims || jsonb_build_object('text', val, 'fact_id', f.id);
          used := array_append(used, fk);
        END IF;
      END IF;
    END LOOP;
    out_mods := out_mods || jsonb_build_object('type', m->>'type', 'header', hdr, 'body', bdy, 'image_brief', COALESCE(m->>'image_brief',''));
  END LOOP;

  RETURN jsonb_build_object(
    'body', jsonb_build_object('modules', out_mods),
    'claims', claims,
    'missing_facts', to_jsonb(missing),
    'brief', format('Từ template "%s" (%s)%s', tpl.name, tpl.use_case, CASE WHEN cardinality(missing) > 0 THEN format(' — thiếu fact: %s', array_to_string(missing, ', ')) ELSE '' END),
    'template', jsonb_build_object('id', tpl.id, 'key', tpl.key, 'name', tpl.name)
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.build_aplus_from_template(UUID, UUID) TO authenticated;

-- ------------------------------------------------------------
-- 3. Gate A+ chi tiết hơn — wrapper quanh check_content_compliance (không sửa hàm 013)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_aplus_modules(p_body JSONB)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE m JSONB; i INT := 0; issues JSONB := '[]'::jsonb; blocks INT := 0; warns INT := 0; hl INT; bl INT; typ TEXT;
BEGIN
  FOR m IN SELECT * FROM jsonb_array_elements(COALESCE(p_body->'modules','[]'::jsonb)) LOOP
    i := i + 1; typ := m->>'type'; hl := length(COALESCE(m->>'header','')); bl := length(COALESCE(m->>'body',''));
    IF hl > 160 THEN issues := issues || jsonb_build_object('code','aplus_header_len','severity','block','msg',format('Module %s: tiêu đề %s ký tự > 160', i, hl)); blocks := blocks + 1; END IF;
    IF typ IN ('standard_image_text','image_header_text') AND bl > 1000 THEN issues := issues || jsonb_build_object('code','aplus_body_len','severity','block','msg',format('Module %s: nội dung %s ký tự > 1000', i, bl)); blocks := blocks + 1; END IF;
    IF typ = 'standard_text' AND bl > 5000 THEN issues := issues || jsonb_build_object('code','aplus_body_len','severity','block','msg',format('Module %s: nội dung %s ký tự > 5000', i, bl)); blocks := blocks + 1; END IF;
    IF typ = 'four_image_text' AND bl > 1000 THEN issues := issues || jsonb_build_object('code','aplus_body_len','severity','block','msg',format('Module %s: mỗi khối ≤ 250 ký tự (tổng ≤ 1000)', i)); blocks := blocks + 1; END IF;
    IF typ IN ('standard_image_text','four_image_text','image_header_text','comparison_chart') AND COALESCE(trim(m->>'image_brief'),'') = '' THEN
      issues := issues || jsonb_build_object('code','aplus_image_brief','severity','warn','msg',format('Module %s (%s) chưa có image brief — designer không có đầu bài', i, typ)); warns := warns + 1;
    END IF;
    IF COALESCE(m->>'body','') ~ 'CHƯA CÓ FACT' THEN issues := issues || jsonb_build_object('code','aplus_missing_fact','severity','block','msg',format('Module %s còn placeholder fact chưa điền', i)); blocks := blocks + 1; END IF;
    IF COALESCE(m->>'body','') ~* '(competitor|đối thủ|brand x|other brands)' THEN issues := issues || jsonb_build_object('code','aplus_competitor','severity','warn','msg',format('Module %s nhắc đến đối thủ — A+ không được so sánh thương hiệu khác', i)); warns := warns + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('blocks', blocks, 'warns', warns, 'issues', issues);
END; $$;

-- Mở rộng gate: gói hàm 013 lại, cộng thêm kết quả A+
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'check_content_compliance_base') THEN
    ALTER FUNCTION public.check_content_compliance(UUID, UUID, TEXT, JSONB, JSONB) RENAME TO check_content_compliance_base;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION public.check_content_compliance(p_tenant UUID, p_sku UUID, p_kind TEXT, p_body JSONB, p_claims JSONB)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE base JSONB; ap JSONB; blocks INT; warns INT;
BEGIN
  base := public.check_content_compliance_base(p_tenant, p_sku, p_kind, p_body, p_claims);
  IF p_kind <> 'aplus' THEN RETURN base; END IF;
  ap := public.check_aplus_modules(p_body);
  blocks := COALESCE((base->>'blocks')::int,0) + (ap->>'blocks')::int;
  warns := COALESCE((base->>'warns')::int,0) + (ap->>'warns')::int;
  RETURN base || jsonb_build_object('ok', blocks = 0, 'blocks', blocks, 'warns', warns, 'issues', COALESCE(base->'issues','[]'::jsonb) || (ap->'issues'));
END; $$;
GRANT EXECUTE ON FUNCTION public.check_content_compliance(UUID, UUID, TEXT, JSONB, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 4. content_cvr_series — chuỗi ngày ±N quanh publish + đối chứng danh mục
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.content_cvr_series(p_version UUID, p_days INT DEFAULT 14)
RETURNS TABLE (date DATE, phase TEXT, sessions INT, units INT, cvr NUMERIC, price NUMERIC, ad_spend NUMERIC, control_cvr NUMERIC, inventory_qty INT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.content_versions%ROWTYPE; d0 DATE;
BEGIN
  SELECT * INTO v FROM public.content_versions WHERE id = p_version;
  IF v.id IS NULL OR v.published_at IS NULL THEN RETURN; END IF;
  IF auth.uid() IS NOT NULL AND NOT (v.tenant_id IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  d0 := v.published_at::date;
  RETURN QUERY
  WITH days AS (SELECT generate_series(d0 - p_days, LEAST(d0 + p_days, CURRENT_DATE), interval '1 day')::date AS d),
  own AS (SELECT s.date, s.sessions, s.units, s.price, s.ad_spend, s.inventory_qty FROM public.sku_daily_snapshots s WHERE s.sku_id = v.sku_id AND s.date BETWEEN d0 - p_days AND d0 + p_days),
  ctrl AS (
    SELECT s.date, SUM(s.units)::numeric / NULLIF(SUM(s.sessions),0) AS cvr
    FROM public.sku_daily_snapshots s JOIN public.amazon_skus k ON k.id = s.sku_id AND k.status = 'active'
    WHERE s.tenant_id = v.tenant_id AND s.sku_id <> v.sku_id AND s.sessions IS NOT NULL AND s.date BETWEEN d0 - p_days AND d0 + p_days
      AND NOT EXISTS (SELECT 1 FROM public.content_versions x WHERE x.sku_id = s.sku_id AND x.published_at::date BETWEEN d0 - p_days AND d0 + p_days)
      AND NOT EXISTS (SELECT 1 FROM public.actions x WHERE x.sku_id = s.sku_id AND x.mode <> 'dry_run' AND x.status IN ('succeeded','rolled_back') AND x.finished_at::date BETWEEN d0 - p_days AND d0 + p_days)
    GROUP BY s.date
  )
  SELECT dd.d, CASE WHEN dd.d < d0 THEN 'before' WHEN dd.d = d0 THEN 'publish' ELSE 'after' END,
         o.sessions, o.units, CASE WHEN o.sessions > 0 THEN round(o.units::numeric / o.sessions, 4) END,
         o.price, o.ad_spend, round(c.cvr, 4), o.inventory_qty
  FROM days dd LEFT JOIN own o ON o.date = dd.d LEFT JOIN ctrl c ON c.date = dd.d ORDER BY dd.d;
END; $$;
GRANT EXECUTE ON FUNCTION public.content_cvr_series(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 5. RLS
-- ------------------------------------------------------------
ALTER TABLE public.aplus_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpl_select ON public.aplus_templates; DROP POLICY IF EXISTS tpl_write ON public.aplus_templates;
CREATE POLICY tpl_select ON public.aplus_templates FOR SELECT TO authenticated USING (tenant_id IS NULL OR tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY tpl_write ON public.aplus_templates FOR ALL TO authenticated
  USING (tenant_id IS NOT NULL AND public.has_permission(tenant_id, 'content.qa_approve'))
  WITH CHECK (tenant_id IS NOT NULL AND public.has_permission(tenant_id, 'content.qa_approve'));
-- audit chỉ cho template của tenant (bản toàn cục không có tenant_id → audit_log.tenant_id NOT NULL)
DROP TRIGGER IF EXISTS trg_aplus_templates_audit ON public.aplus_templates;
DROP TRIGGER IF EXISTS trg_aplus_templates_audit_ins ON public.aplus_templates;
DROP TRIGGER IF EXISTS trg_aplus_templates_audit_upd ON public.aplus_templates;
DROP TRIGGER IF EXISTS trg_aplus_templates_audit_del ON public.aplus_templates;
CREATE TRIGGER trg_aplus_templates_audit_ins AFTER INSERT ON public.aplus_templates FOR EACH ROW WHEN (NEW.tenant_id IS NOT NULL) EXECUTE FUNCTION public.write_audit_log();
CREATE TRIGGER trg_aplus_templates_audit_upd AFTER UPDATE ON public.aplus_templates FOR EACH ROW WHEN (NEW.tenant_id IS NOT NULL) EXECUTE FUNCTION public.write_audit_log();
CREATE TRIGGER trg_aplus_templates_audit_del AFTER DELETE ON public.aplus_templates FOR EACH ROW WHEN (OLD.tenant_id IS NOT NULL) EXECUTE FUNCTION public.write_audit_log();

DO $$ BEGIN RAISE NOTICE '017_aplus_cvr.sql đã nạp (templates: %)', (SELECT count(*) FROM public.aplus_templates WHERE tenant_id IS NULL); END $$;
