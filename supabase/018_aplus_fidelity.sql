-- ============================================================
-- 018 — P1: A+ module fidelity (khớp Amazon A+ Content Manager)
--   aplus_module_specs (17 module Standard + Premium; trường, giới hạn ký tự, ảnh tối thiểu, alt‑text)
--   gate A+ v2: Standard ≤ 5 module (Premium ≤ 7 khi policy bật), đúng giới hạn từng trường, alt‑text, giá/khuyến mãi/link ngoài
--   build_aplus_from_template v2: điền {fact:key} ở mọi trường lồng nhau; template viết lại trên module thật
--   nâng cấp body cũ (header/body/image_brief) khi đọc — không sửa dữ liệu lịch sử
-- Chạy SAU 017. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Đặc tả module (nguồn sự thật phía DB; lib/aplus.ts là bản TypeScript tương đương)
--    fields: [{key,label,type:text|textarea|image|list|table,max,required,factable,minW,minH,count,item:[..],maxRows,cols:[..]}]
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.aplus_module_specs (
  type        TEXT PRIMARY KEY,
  amazon_name TEXT NOT NULL,
  premium     BOOLEAN NOT NULL DEFAULT false,
  fields      JSONB NOT NULL,
  note        TEXT
);
INSERT INTO public.aplus_module_specs (type, amazon_name, premium, fields, note) VALUES
('standard_company_logo','Standard Company Logo',false,'[{"key":"image","type":"image","minW":600,"minH":180,"required":true},{"key":"alt","type":"text","max":100,"required":true}]',NULL),
('standard_image_header_text','Standard Image Header With Text',false,'[{"key":"image","type":"image","minW":970,"minH":600,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":150,"required":true},{"key":"subheadline","type":"text","max":150},{"key":"body","type":"textarea","max":6000,"factable":true}]',NULL),
('standard_text','Standard Text',false,'[{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":5000,"required":true,"factable":true}]',NULL),
('standard_product_description_text','Standard Product Description Text',false,'[{"key":"body","type":"textarea","max":6000,"required":true,"factable":true}]',NULL),
('standard_single_left_image','Standard Single Left Image',false,'[{"key":"image","type":"image","minW":300,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":1000,"required":true,"factable":true}]',NULL),
('standard_single_right_image','Standard Single Right Image',false,'[{"key":"image","type":"image","minW":300,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":1000,"required":true,"factable":true}]',NULL),
('standard_single_image_highlights','Standard Single Image & Highlights',false,'[{"key":"image","type":"image","minW":300,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"subheadline","type":"text","max":200},{"key":"body","type":"textarea","max":1000,"factable":true},{"key":"highlights","type":"list","count":8,"item":[{"key":"text","type":"text","max":100,"factable":true}]}]',NULL),
('standard_single_image_sidebar','Standard Single Image & Sidebar',false,'[{"key":"image","type":"image","minW":300,"minH":400,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":500,"required":true,"factable":true},{"key":"sidebar_image","type":"image","minW":350,"minH":175},{"key":"sidebar_headline","type":"text","max":160},{"key":"sidebar_body","type":"textarea","max":500,"factable":true}]',NULL),
('standard_single_image_specs_detail','Standard Single Image & Specs Detail',false,'[{"key":"image","type":"image","minW":300,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":1000,"factable":true},{"key":"specs","type":"table","maxRows":16,"cols":[{"key":"name","max":30},{"key":"value","max":500}]}]',NULL),
('standard_three_image_text','Standard Three Images & Text',false,'[{"key":"headline","type":"text","max":200},{"key":"blocks","type":"list","count":3,"item":[{"key":"image","type":"image","minW":300,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":1000,"factable":true}]}]',NULL),
('standard_four_image_text','Standard Four Image & Text',false,'[{"key":"headline","type":"text","max":200},{"key":"blocks","type":"list","count":4,"item":[{"key":"image","type":"image","minW":220,"minH":220,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":1000,"factable":true}]}]',NULL),
('standard_four_image_text_quadrant','Standard Four Image/Text Quadrant',false,'[{"key":"blocks","type":"list","count":4,"item":[{"key":"image","type":"image","minW":135,"minH":135,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":140},{"key":"body","type":"textarea","max":1000,"factable":true}]}]',NULL),
('standard_multiple_image_module_a','Standard Multiple Image Module A',false,'[{"key":"blocks","type":"list","count":4,"item":[{"key":"image","type":"image","minW":300,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"caption","type":"text","max":200},{"key":"headline","type":"text","max":160},{"key":"body","type":"textarea","max":1000,"factable":true}]}]',NULL),
('standard_image_text_overlay','Standard Image & Light/Dark Text Overlay',false,'[{"key":"image","type":"image","minW":970,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"overlay","type":"text","max":5},{"key":"headline","type":"text","max":70},{"key":"body","type":"textarea","max":300,"factable":true}]',NULL),
('standard_comparison_chart','Standard Comparison Chart',false,'[{"key":"products","type":"list","count":6,"item":[{"key":"image","type":"image","minW":150,"minH":300,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"asin","type":"text","max":10,"required":true},{"key":"title","type":"text","max":80}]},{"key":"metrics","type":"table","maxRows":10,"cols":[{"key":"name","max":20},{"key":"values","max":600}]}]','Chỉ so sánh ASIN của chính thương hiệu'),
('standard_tech_specs','Standard Technical Specifications',false,'[{"key":"headline","type":"text","max":160},{"key":"specs","type":"table","maxRows":16,"cols":[{"key":"name","max":30},{"key":"value","max":500}]}]',NULL),
('premium_full_image','Premium Full Image',true,'[{"key":"image","type":"image","minW":1464,"minH":600,"required":true},{"key":"alt","type":"text","max":100,"required":true},{"key":"headline","type":"text","max":80},{"key":"body","type":"textarea","max":500,"factable":true}]',NULL)
ON CONFLICT (type) DO UPDATE SET amazon_name = EXCLUDED.amazon_name, premium = EXCLUDED.premium, fields = EXCLUDED.fields, note = EXCLUDED.note;
ALTER TABLE public.aplus_module_specs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS specs_select ON public.aplus_module_specs;
CREATE POLICY specs_select ON public.aplus_module_specs FOR SELECT TO authenticated USING (true);

-- Premium A+ theo tenant (Amazon cấp theo brand)
ALTER TABLE public.policy_register ADD COLUMN IF NOT EXISTS aplus_premium_enabled BOOLEAN NOT NULL DEFAULT false;

-- ------------------------------------------------------------
-- 2. Nâng cấp module cũ → cấu trúc mới (đọc), không đụng dữ liệu lịch sử
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aplus_upgrade_module(m JSONB)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE t TEXT := m->>'type'; nt TEXT; o JSONB;
BEGIN
  IF NOT (m ? 'header') THEN RETURN m; END IF;   -- đã là cấu trúc mới
  nt := CASE t WHEN 'standard_image_text' THEN 'standard_single_left_image' WHEN 'image_header_text' THEN 'standard_image_header_text'
               WHEN 'four_image_text' THEN 'standard_four_image_text' WHEN 'comparison_chart' THEN 'standard_comparison_chart'
               WHEN 'tech_specs' THEN 'standard_tech_specs' WHEN 'standard_text' THEN 'standard_text' ELSE 'standard_single_left_image' END;
  o := jsonb_build_object('type', nt, 'headline', COALESCE(m->>'header',''), 'body', COALESCE(m->>'body',''), 'image', jsonb_build_object('brief', COALESCE(m->>'image_brief',''), 'url', ''), 'alt', '');
  IF nt = 'standard_tech_specs' THEN
    o := o - 'body' || jsonb_build_object('specs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', left(split_part(l, ':', 1), 30), 'value', trim(substr(l, position(':' in l) + 1)))), '[]'::jsonb)
                                                          FROM unnest(string_to_array(COALESCE(m->>'body',''), E'\n')) l WHERE l <> ''));
  END IF;
  RETURN o;
END; $$;

CREATE OR REPLACE FUNCTION public.aplus_upgrade_body(b JSONB)
RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('modules', COALESCE((SELECT jsonb_agg(public.aplus_upgrade_module(m)) FROM jsonb_array_elements(COALESCE(b->'modules','[]'::jsonb)) m), '[]'::jsonb));
$$;

-- ------------------------------------------------------------
-- 3. Gate v2 — kiểm tra đệ quy theo spec
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._aplus_check_fields(p_fields JSONB, p_data JSONB, p_path TEXT, INOUT issues JSONB, INOUT blocks INT, INOUT warns INT)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE f JSONB; v JSONB; k TEXT; typ TEXT; s TEXT; i INT; n INT; c JSONB;
BEGIN
  FOR f IN SELECT * FROM jsonb_array_elements(p_fields) LOOP
    k := f->>'key'; typ := f->>'type'; v := p_data->k;
    IF typ IN ('text','textarea') THEN
      s := COALESCE(v #>> '{}', '');
      IF COALESCE((f->>'required')::boolean,false) AND trim(s) = '' THEN issues := issues || jsonb_build_object('code','aplus_required','severity','block','msg',format('%s: thiếu trường "%s"', p_path, k)); blocks := blocks + 1; END IF;
      IF length(s) > (f->>'max')::int THEN issues := issues || jsonb_build_object('code','aplus_len','severity','block','msg',format('%s: "%s" %s ký tự > %s', p_path, k, length(s), f->>'max')); blocks := blocks + 1; END IF;
      IF s ~ 'CHƯA CÓ FACT' THEN issues := issues || jsonb_build_object('code','aplus_missing_fact','severity','block','msg',format('%s: "%s" còn placeholder fact chưa điền', p_path, k)); blocks := blocks + 1; END IF;
      IF k = 'alt' AND trim(s) = '' THEN issues := issues || jsonb_build_object('code','aplus_alt','severity','warn','msg',format('%s: thiếu alt‑text ảnh (SEO + accessibility)', p_path)); warns := warns + 1; END IF;
    ELSIF typ = 'image' THEN
      IF COALESCE((f->>'required')::boolean,false) AND COALESCE(trim(v->>'brief'),'') = '' AND COALESCE(trim(v->>'url'),'') = '' THEN
        issues := issues || jsonb_build_object('code','aplus_image_brief','severity','warn','msg',format('%s: ảnh "%s" chưa có brief/URL (tối thiểu %s×%s px)', p_path, k, f->>'minW', f->>'minH')); warns := warns + 1;
      END IF;
    ELSIF typ = 'list' THEN
      n := jsonb_array_length(COALESCE(v,'[]'::jsonb));
      IF n > (f->>'count')::int THEN issues := issues || jsonb_build_object('code','aplus_list_count','severity','block','msg',format('%s: "%s" có %s mục > %s', p_path, k, n, f->>'count')); blocks := blocks + 1; END IF;
      IF k = 'products' AND n < 2 THEN issues := issues || jsonb_build_object('code','aplus_list_count','severity','block','msg',format('%s: bảng so sánh cần ≥ 2 sản phẩm', p_path)); blocks := blocks + 1; END IF;
      FOR i IN 0..GREATEST(n-1,0) LOOP
        IF n > 0 THEN SELECT * INTO issues, blocks, warns FROM public._aplus_check_fields(f->'item', v->i, format('%s › %s %s', p_path, k, i+1), issues, blocks, warns); END IF;
      END LOOP;
    ELSIF typ = 'table' THEN
      n := jsonb_array_length(COALESCE(v,'[]'::jsonb));
      IF n > (f->>'maxRows')::int THEN issues := issues || jsonb_build_object('code','aplus_table_rows','severity','block','msg',format('%s: "%s" %s dòng > %s', p_path, k, n, f->>'maxRows')); blocks := blocks + 1; END IF;
      FOR i IN 0..GREATEST(n-1,0) LOOP
        IF n > 0 THEN
          FOR c IN SELECT * FROM jsonb_array_elements(f->'cols') LOOP
            s := COALESCE(v->i->>(c->>'key'),'');
            IF length(s) > (c->>'max')::int THEN issues := issues || jsonb_build_object('code','aplus_len','severity','block','msg',format('%s: dòng %s cột "%s" %s ký tự > %s', p_path, i+1, c->>'key', length(s), c->>'max')); blocks := blocks + 1; END IF;
            IF s ~ 'CHƯA CÓ FACT' THEN issues := issues || jsonb_build_object('code','aplus_missing_fact','severity','block','msg',format('%s: dòng %s còn placeholder fact', p_path, i+1)); blocks := blocks + 1; END IF;
          END LOOP;
        END IF;
      END LOOP;
    END IF;
  END LOOP;
END; $$;

CREATE OR REPLACE FUNCTION public.check_aplus_modules_v2(p_tenant UUID, p_body JSONB)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE body JSONB; m JSONB; i INT := 0; issues JSONB := '[]'::jsonb; blocks INT := 0; warns INT := 0; spec public.aplus_module_specs; n INT; premium BOOLEAN; maxm INT; txt TEXT; path TEXT; bt RECORD;
BEGIN
  body := public.aplus_upgrade_body(p_body);
  SELECT COALESCE(aplus_premium_enabled,false) INTO premium FROM public.policy_register WHERE tenant_id = p_tenant;
  premium := COALESCE(premium, false); maxm := CASE WHEN premium THEN 7 ELSE 5 END;
  n := jsonb_array_length(body->'modules');
  IF n = 0 THEN issues := issues || jsonb_build_object('code','aplus_modules','severity','block','msg','A+ cần ít nhất 1 module'); blocks := blocks + 1; END IF;
  IF n > maxm THEN issues := issues || jsonb_build_object('code','aplus_modules','severity','block','msg',format('%s module > %s (%s A+)', n, maxm, CASE WHEN premium THEN 'Premium' ELSE 'Standard' END)); blocks := blocks + 1; END IF;
  FOR m IN SELECT * FROM jsonb_array_elements(body->'modules') LOOP
    i := i + 1; path := format('Module %s', i);
    SELECT * INTO spec FROM public.aplus_module_specs WHERE type = m->>'type';
    IF spec.type IS NULL THEN issues := issues || jsonb_build_object('code','aplus_type','severity','block','msg',format('%s: type "%s" không hợp lệ', path, m->>'type')); blocks := blocks + 1; CONTINUE; END IF;
    IF spec.premium AND NOT premium THEN issues := issues || jsonb_build_object('code','aplus_premium','severity','block','msg',format('%s: %s là module Premium — tenant chưa bật Premium A+', path, spec.amazon_name)); blocks := blocks + 1; END IF;
    SELECT * INTO issues, blocks, warns FROM public._aplus_check_fields(spec.fields, m, path, issues, blocks, warns);
    -- nội dung cấm đặc thù A+ (+ từ cấm của tenant trên toàn bộ module, kể cả headline/alt)
    txt := m::text;
    FOR bt IN SELECT term, severity, reason FROM public.content_banned_terms WHERE tenant_id IS NULL OR tenant_id = p_tenant LOOP
      IF txt ~* ('\m' || regexp_replace(bt.term, '([.*+?^${}()|\[\]\\#])', '\\\1', 'g') || '\M') THEN
        issues := issues || jsonb_build_object('code','banned_term','severity',bt.severity,'msg',format('%s: "%s" — %s', path, bt.term, bt.reason));
        IF bt.severity = 'block' THEN blocks := blocks + 1; ELSE warns := warns + 1; END IF;
      END IF;
    END LOOP;
    IF txt ~* '(competitor|đối thủ|other brands?|brand x)' THEN issues := issues || jsonb_build_object('code','aplus_competitor','severity','warn','msg',format('%s: nhắc đến đối thủ — A+ không được so sánh thương hiệu khác', path)); warns := warns + 1; END IF;
    IF txt ~* '(\$\s?\d|\d\s?(usd|đ|vnd)|giảm giá|khuyến mãi|sale off|discount|free shipping|miễn phí vận chuyển|limited time|chỉ hôm nay)' THEN issues := issues || jsonb_build_object('code','aplus_price_promo','severity','block','msg',format('%s: có giá/khuyến mãi/thời hạn — A+ cấm', path)); blocks := blocks + 1; END IF;
    IF txt ~* '(https?://|www\.|\.com\b|@[a-z0-9]+\.[a-z]{2,}|zalo|whatsapp|hotline)' THEN issues := issues || jsonb_build_object('code','aplus_external','severity','block','msg',format('%s: có link/thông tin liên hệ ngoài Amazon — cấm', path)); blocks := blocks + 1; END IF;
    IF txt ~* '(guarantee|đảm bảo 100|best seller|#1|number one|top rated|award[- ]winning|cheapest|rẻ nhất)' THEN issues := issues || jsonb_build_object('code','aplus_claim','severity','block','msg',format('%s: claim tuyệt đối/giải thưởng không kèm bằng chứng', path)); blocks := blocks + 1; END IF;
    IF (m->>'type') = 'standard_comparison_chart' THEN
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(m->'products','[]'::jsonb)) p WHERE COALESCE(p->>'asin','') <> '' AND NOT EXISTS (SELECT 1 FROM public.amazon_skus k WHERE k.tenant_id = p_tenant AND k.asin = p->>'asin')) THEN
        issues := issues || jsonb_build_object('code','aplus_comparison_foreign','severity','block','msg',format('%s: bảng so sánh có ASIN không thuộc brand này', path)); blocks := blocks + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('blocks', blocks, 'warns', warns, 'issues', issues, 'max_modules', maxm, 'premium', premium);
END; $$;

-- Gate tổng: base (013) + A+ v2 (thay v1 của 017)
CREATE OR REPLACE FUNCTION public.check_content_compliance(p_tenant UUID, p_sku UUID, p_kind TEXT, p_body JSONB, p_claims JSONB)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE base JSONB; ap JSONB; blocks INT; warns INT; base_issues JSONB;
BEGIN
  IF p_kind <> 'aplus' THEN RETURN public.check_content_compliance_base(p_tenant, p_sku, p_kind, p_body, p_claims); END IF;
  -- base 013 với body đã nâng cấp; bỏ 2 rule cũ (1–7 module, type cũ) vì v2 thay thế
  base := public.check_content_compliance_base(p_tenant, p_sku, p_kind, public.aplus_upgrade_body(p_body), p_claims);
  base_issues := COALESCE((SELECT jsonb_agg(i) FROM jsonb_array_elements(COALESCE(base->'issues','[]'::jsonb)) i WHERE i->>'code' NOT IN ('aplus_modules','aplus_type','banned_term')), '[]'::jsonb);
  ap := public.check_aplus_modules_v2(p_tenant, p_body);
  blocks := (SELECT count(*) FROM jsonb_array_elements(base_issues) i WHERE i->>'severity' = 'block') + (ap->>'blocks')::int;
  warns  := (SELECT count(*) FROM jsonb_array_elements(base_issues) i WHERE i->>'severity' = 'warn')  + (ap->>'warns')::int;
  RETURN base || jsonb_build_object('ok', blocks = 0, 'blocks', blocks, 'warns', warns, 'issues', base_issues || (ap->'issues'), 'max_modules', ap->'max_modules', 'premium', ap->'premium');
END; $$;
GRANT EXECUTE ON FUNCTION public.check_content_compliance(UUID, UUID, TEXT, JSONB, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 4. Template trên module thật + build v2 (điền đệ quy)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._aplus_fill(p_val JSONB, p_sku UUID, p_title TEXT, p_brand TEXT, INOUT claims JSONB, INOUT missing TEXT[], INOUT used TEXT[], OUT result JSONB)
LANGUAGE plpgsql STABLE AS $$
DECLARE s TEXT; fk TEXT; f RECORD; val TEXT; k TEXT; v JSONB; o JSONB; i INT;
BEGIN
  IF jsonb_typeof(p_val) = 'string' THEN
    s := replace(replace(p_val #>> '{}', '{title}', COALESCE(p_title,'')), '{brand}', COALESCE(p_brand,''));
    FOR fk IN SELECT DISTINCT x[1] FROM regexp_matches(s, '\{fact:([a-z0-9_]+)\}', 'g') AS x LOOP
      SELECT id, value, unit INTO f FROM public.product_facts WHERE sku_id = p_sku AND key = fk AND status = 'verified' ORDER BY updated_at DESC LIMIT 1;
      IF f.id IS NULL THEN
        IF NOT (fk = ANY(missing)) THEN missing := array_append(missing, fk); END IF;
        s := replace(s, '{fact:' || fk || '}', '[' || fk || ': CHƯA CÓ FACT]');
      ELSE
        val := f.value || COALESCE(' ' || f.unit, '');
        s := replace(s, '{fact:' || fk || '}', val);
        IF NOT (fk = ANY(used)) THEN claims := claims || jsonb_build_object('text', val, 'fact_id', f.id); used := array_append(used, fk); END IF;
      END IF;
    END LOOP;
    result := to_jsonb(s); RETURN;
  ELSIF jsonb_typeof(p_val) = 'object' THEN
    o := '{}'::jsonb;
    FOR k, v IN SELECT * FROM jsonb_each(p_val) LOOP
      IF k = 'required_facts' THEN CONTINUE; END IF;
      SELECT * INTO claims, missing, used, v FROM public._aplus_fill(v, p_sku, p_title, p_brand, claims, missing, used);
      o := o || jsonb_build_object(k, v);
    END LOOP;
    result := o; RETURN;
  ELSIF jsonb_typeof(p_val) = 'array' THEN
    o := '[]'::jsonb;
    FOR i IN 0..GREATEST(jsonb_array_length(p_val)-1, 0) LOOP
      IF jsonb_array_length(p_val) > 0 THEN
        SELECT * INTO claims, missing, used, v FROM public._aplus_fill(p_val->i, p_sku, p_title, p_brand, claims, missing, used);
        o := o || jsonb_build_array(v);
      END IF;
    END LOOP;
    result := o; RETURN;
  END IF;
  result := p_val;
END; $$;

CREATE OR REPLACE FUNCTION public.build_aplus_from_template(p_template UUID, p_sku UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE tpl public.aplus_templates; k public.amazon_skus; brand TEXT; claims JSONB := '[]'::jsonb; missing TEXT[] := '{}'; used TEXT[] := '{}'; mods JSONB;
BEGIN
  SELECT * INTO tpl FROM public.aplus_templates WHERE id = p_template AND is_active;
  IF tpl.id IS NULL THEN RAISE EXCEPTION 'Template không tồn tại'; END IF;
  SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  IF k.id IS NULL THEN RAISE EXCEPTION 'SKU không tồn tại'; END IF;
  IF auth.uid() IS NOT NULL AND NOT (k.tenant_id IN (SELECT public.my_tenant_ids())) THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  IF tpl.tenant_id IS NOT NULL AND tpl.tenant_id <> k.tenant_id THEN RAISE EXCEPTION 'Template thuộc tenant khác'; END IF;
  brand := COALESCE((SELECT value FROM public.product_facts WHERE sku_id = p_sku AND key = 'brand' AND status = 'verified' LIMIT 1), (SELECT name FROM public.tenants WHERE id = k.tenant_id));
  SELECT * INTO claims, missing, used, mods FROM public._aplus_fill(public.aplus_upgrade_body(jsonb_build_object('modules', tpl.modules))->'modules', p_sku, k.title, brand, claims, missing, used);
  RETURN jsonb_build_object(
    'body', jsonb_build_object('modules', mods), 'claims', claims, 'missing_facts', to_jsonb(missing),
    'brief', format('Từ template "%s" (%s)%s', tpl.name, tpl.use_case, CASE WHEN cardinality(missing) > 0 THEN format(' — thiếu fact: %s', array_to_string(missing, ', ')) ELSE '' END),
    'template', jsonb_build_object('id', tpl.id, 'key', tpl.key, 'name', tpl.name));
END; $$;
GRANT EXECUTE ON FUNCTION public.build_aplus_from_template(UUID, UUID) TO authenticated;

-- Template toàn cục viết lại trên module Amazon (≤ 5 module = Standard)
UPDATE public.aplus_templates SET modules = '[
 {"type":"standard_image_header_text","image":{"brief":"Ảnh hero 970×600: sản phẩm trong bối cảnh sử dụng thật, nền sáng, không chữ chồng lên sản phẩm.","url":""},"alt":"{brand} {title}","headline":"{brand} — {title}","subheadline":"","body":"Một đoạn định vị: sản phẩm giải quyết vấn đề gì, cho ai. Không dùng từ tuyệt đối."},
 {"type":"standard_single_image_highlights","image":{"brief":"Cận cảnh chi tiết thể hiện lợi ích chính.","url":""},"alt":"{title} chi tiết","headline":"Lợi ích chính","subheadline":"Dựa trên thông số đã xác minh","body":"Chất liệu {fact:material}, dung tích {fact:capacity}.","highlights":[{"text":"Dung tích {fact:capacity}"},{"text":"Chất liệu {fact:material}"},{"text":"Bảo hành {fact:warranty}"}]},
 {"type":"standard_tech_specs","headline":"Thông số kỹ thuật","specs":[{"name":"Kích thước","value":"{fact:dimensions}"},{"name":"Trọng lượng","value":"{fact:weight}"},{"name":"Chất liệu","value":"{fact:material}"},{"name":"Dung tích","value":"{fact:capacity}"}]},
 {"type":"standard_four_image_text","headline":"Cách sử dụng","blocks":[{"image":{"brief":"Bước 1","url":""},"alt":"Bước 1","headline":"Bước 1","body":""},{"image":{"brief":"Bước 2","url":""},"alt":"Bước 2","headline":"Bước 2","body":""},{"image":{"brief":"Bước 3","url":""},"alt":"Bước 3","headline":"Bước 3","body":""},{"image":{"brief":"Bước 4","url":""},"alt":"Bước 4","headline":"Bước 4","body":""}]},
 {"type":"standard_text","headline":"Cam kết & hỗ trợ","body":"Chính sách bảo hành {fact:warranty}. Liên hệ qua Amazon Buyer‑Seller Messaging."}
]'::jsonb, description = 'Image Header → Highlights → Tech Specs → Four Image & Text → Text. Phù hợp SKU mới chưa có A+ (5 module = Standard).' WHERE tenant_id IS NULL AND key = 'launch_basic';

UPDATE public.aplus_templates SET modules = '[
 {"type":"standard_image_header_text","image":{"brief":"Ảnh hero thể hiện điểm khác biệt.","url":""},"alt":"Vì sao chọn {brand}","headline":"Vì sao chọn {brand}","subheadline":"","body":"Nêu 1 vấn đề phổ biến (từ VoC) và cách sản phẩm giải quyết, dựa trên fact."},
 {"type":"standard_single_left_image","image":{"brief":"Ảnh chứng nhận/kết quả kiểm nghiệm nếu có fact lab_test.","url":""},"alt":"{fact:material}","headline":"Điểm khác biệt 1","body":"Bằng chứng: {fact:material} · {fact:certification}"},
 {"type":"standard_single_right_image","image":{"brief":"Ảnh so sánh kích thước với vật quen thuộc.","url":""},"alt":"{title} kích thước","headline":"Điểm khác biệt 2","body":"Bằng chứng số: {fact:capacity} / {fact:weight}"},
 {"type":"standard_comparison_chart","products":[{"image":{"brief":"Thumbnail SKU này","url":""},"alt":"{title}","asin":"","title":"{title}"},{"image":{"brief":"Thumbnail SKU khác cùng brand","url":""},"alt":"","asin":"","title":""}],"metrics":[{"name":"Dung tích","values":"{fact:capacity} | "},{"name":"Chất liệu","values":"{fact:material} | "},{"name":"Bảo hành","values":"{fact:warranty} | "}]}
]'::jsonb, description = 'Image Header → Single Left → Single Right → Comparison Chart (chỉ SKU cùng brand).' WHERE tenant_id IS NULL AND key = 'differentiation';

UPDATE public.aplus_templates SET modules = '[
 {"type":"standard_single_left_image","image":{"brief":"Ảnh chất liệu cận cảnh + logo chứng nhận (nếu có).","url":""},"alt":"{fact:material}","headline":"Chất liệu & tiêu chuẩn","body":"{fact:material}. Chứng nhận: {fact:certification}."},
 {"type":"standard_four_image_text","headline":"Kiểm soát chất lượng","blocks":[{"image":{"brief":"QC bước 1","url":""},"alt":"QC 1","headline":"Kiểm tra nguyên liệu","body":""},{"image":{"brief":"QC bước 2","url":""},"alt":"QC 2","headline":"Kiểm tra trong sản xuất","body":""},{"image":{"brief":"QC bước 3","url":""},"alt":"QC 3","headline":"Kiểm tra thành phẩm","body":""},{"image":{"brief":"QC bước 4","url":""},"alt":"QC 4","headline":"Đóng gói","body":""}]},
 {"type":"standard_text","headline":"Bảo hành {fact:warranty}","body":"Điều kiện bảo hành và cách yêu cầu qua Amazon."},
 {"type":"standard_tech_specs","headline":"Thông số","specs":[{"name":"Kích thước","value":"{fact:dimensions}"},{"name":"Trọng lượng","value":"{fact:weight}"}]}
]'::jsonb, description = 'Single Left → Four Image & Text (QC) → Text (bảo hành) → Tech Specs. Khi VoC có QUALITY/DEFECT.' WHERE tenant_id IS NULL AND key = 'trust_quality';

UPDATE public.aplus_templates SET modules = '[
 {"type":"standard_image_header_text","image":{"brief":"Sản phẩm cạnh vật tham chiếu (bàn tay, chai 500 ml).","url":""},"alt":"{title} kích thước thực","headline":"Đúng kích thước cho nhu cầu của bạn","subheadline":"","body":"Kích thước thực {fact:dimensions}, dung tích {fact:capacity}."},
 {"type":"standard_four_image_text","headline":"4 bước sử dụng","blocks":[{"image":{"brief":"Thao tác 1","url":""},"alt":"Bước 1","headline":"Bước 1","body":""},{"image":{"brief":"Thao tác 2","url":""},"alt":"Bước 2","headline":"Bước 2","body":""},{"image":{"brief":"Thao tác 3","url":""},"alt":"Bước 3","headline":"Bước 3","body":""},{"image":{"brief":"Thao tác 4","url":""},"alt":"Bước 4","headline":"Bước 4","body":""}]},
 {"type":"standard_single_right_image","image":{"brief":"Ảnh minh hoạ vệ sinh.","url":""},"alt":"Bảo quản {title}","headline":"Bảo quản & vệ sinh","body":"Hướng dẫn phù hợp chất liệu {fact:material}."},
 {"type":"standard_text","headline":"Câu hỏi thường gặp","body":"3–5 câu hỏi lấy từ review/tickets VoC, trả lời dựa trên fact."}
]'::jsonb, description = 'Image Header → Four Image & Text → Single Right → Text (FAQ). Khi VoC có SIZE/kỳ vọng sai.' WHERE tenant_id IS NULL AND key = 'howto_usage';

DO $$ BEGIN RAISE NOTICE '018_aplus_fidelity.sql đã nạp (module specs: %)', (SELECT count(*) FROM public.aplus_module_specs); END $$;
