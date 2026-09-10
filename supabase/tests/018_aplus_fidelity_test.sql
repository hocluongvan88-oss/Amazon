-- ============================================================
-- Test 018 — chạy trong SQL Editor SAU 018. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sk1 UUID; sku2 UUID; tpl UUID; built JSONB; gate JSONB; up JSONB; n INT; rv UUID; m5 JSONB;
  u_op UUID := gen_random_uuid(); u_qa UUID := gen_random_uuid(); u_view UUID := gen_random_uuid(); u UUID;
  _r RECORD; _fails INT := 0; _out TEXT := '';
BEGIN
  CREATE TEMP TABLE _t (name TEXT, ok BOOLEAN) ON COMMIT DROP;
  EXECUTE $f$CREATE OR REPLACE FUNCTION pg_temp.as_user(u UUID) RETURNS VOID LANGUAGE sql AS $b$
    SELECT set_config('request.jwt.claims', json_build_object('sub', u::text, 'email', u::text || '@test.local', 'role', 'authenticated')::text, true);
  $b$ $f$;
  EXECUTE $f$CREATE OR REPLACE FUNCTION pg_temp.expect_error(name TEXT, sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$
  BEGIN BEGIN EXECUTE sql; INSERT INTO _t VALUES (name, false); EXCEPTION WHEN OTHERS THEN INSERT INTO _t VALUES (name, true); END; END $b$ $f$;
  EXECUTE $f$CREATE OR REPLACE FUNCTION pg_temp.expect_ok(name TEXT, sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$
  BEGIN BEGIN EXECUTE sql; INSERT INTO _t VALUES (name, true); EXCEPTION WHEN OTHERS THEN INSERT INTO _t VALUES (name || ' (' || SQLERRM || ')', false); END; END $b$ $f$;

  FOREACH u IN ARRAY ARRAY[u_op,u_qa,u_view] LOOP
    INSERT INTO auth.users (id, email, instance_id, aud, role, encrypted_password, created_at, updated_at)
    VALUES (u, u::text || '@test.local', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), now());
  END LOOP;
  INSERT INTO public.tenants (slug, name) VALUES ('t018', 'Test 018') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'owner'), (t, u_view, 'viewer');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
  VALUES (t, 'B0TEST0018', 'T-018', 'Bình nước', 'US', 30, 10, 5, 15, 0) RETURNING id INTO sk1;
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at) VALUES (t, 'B0TEST0018', 1, 'Leaks', 'Nắp bị rò', now()) RETURNING id INTO rv;

  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.product_facts (tenant_id, sku_id, key, value, unit, source_type, source_ref) VALUES
    (t, sk1, 'material', 'Gốm men rạn', NULL, 'supplier', 'spec.pdf'), (t, sk1, 'capacity', '350', 'ml', 'document', 'spec.pdf'), (t, sk1, 'warranty', '12 tháng', NULL, 'manual', NULL);
  UPDATE public.product_facts SET status = 'verified' WHERE tenant_id = t AND key IN ('material','capacity');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
    VALUES (t, 'B0SIBLING18', 'S-2', 'Cốc bộ 4', 'US', 40, 12, 6, 15, 100) RETURNING id INTO sku2;

  -- 1. Specs
  INSERT INTO _t SELECT 'specs: 17 modules seeded', (SELECT count(*) FROM public.aplus_module_specs) = 17;
  INSERT INTO _t SELECT 'specs: premium flagged', (SELECT premium FROM public.aplus_module_specs WHERE type = 'premium_full_image');
  INSERT INTO _t SELECT 'policy: aplus_premium_enabled default false', (SELECT COALESCE(aplus_premium_enabled,false) FROM public.policy_register WHERE tenant_id = t) = false OR NOT EXISTS (SELECT 1 FROM public.policy_register WHERE tenant_id = t);

  -- 2. Nâng cấp body cũ
  up := public.aplus_upgrade_body('{"modules":[{"type":"standard_image_text","header":"H","body":"B","image_brief":"I"},{"type":"tech_specs","header":"Specs","body":"Kích thước: 10x10\nTrọng lượng: 300 g"}]}'::jsonb);
  INSERT INTO _t SELECT 'upgrade: legacy image_text → single_left_image', up->'modules'->0->>'type' = 'standard_single_left_image' AND up->'modules'->0->>'headline' = 'H' AND up->'modules'->0->'image'->>'brief' = 'I';
  INSERT INTO _t SELECT 'upgrade: legacy tech_specs → table', up->'modules'->1->>'type' = 'standard_tech_specs' AND jsonb_array_length(up->'modules'->1->'specs') = 2 AND up->'modules'->1->'specs'->1->>'value' = '300 g';
  INSERT INTO _t SELECT 'upgrade: new-format untouched', public.aplus_upgrade_body('{"modules":[{"type":"standard_text","headline":"x","body":"y"}]}'::jsonb)->'modules'->0->>'headline' = 'x';

  -- 3. Template build v2 (điền đệ quy)
  PERFORM pg_temp.as_user(u_op);
  SELECT id INTO tpl FROM public.aplus_templates WHERE tenant_id IS NULL AND key = 'launch_basic';
  built := public.build_aplus_from_template(tpl, sk1);
  INSERT INTO _t SELECT 'build: 5 real modules', jsonb_array_length(built->'body'->'modules') = 5 AND built->'body'->'modules'->0->>'type' = 'standard_image_header_text';
  INSERT INTO _t SELECT 'build: nested highlight filled', built->'body'->'modules'->1->'highlights'->0->>'text' = 'Dung tích 350 ml';
  INSERT INTO _t SELECT 'build: tech_specs table filled + missing placeholder', built->'body'->'modules'->2->'specs'->3->>'value' = '350 ml' AND built->'body'->'modules'->2->'specs'->0->>'value' LIKE '%CHƯA CÓ FACT%';
  INSERT INTO _t SELECT 'build: alt filled with brand/title', built->'body'->'modules'->0->>'alt' LIKE '%Bình nước%';
  INSERT INTO _t SELECT 'build: claims 2 (material, capacity)', jsonb_array_length(built->'claims') = 2;
  INSERT INTO _t SELECT 'build: missing lists dimensions/weight/warranty', (built->'missing_facts') @> '["dimensions","weight","warranty"]'::jsonb;

  -- 4. Gate v2
  gate := public.check_content_compliance(t, sk1, 'aplus', built->'body', built->'claims');
  INSERT INTO _t SELECT 'gate: placeholder blocks', (gate->>'ok')::boolean = false AND (gate->'issues') @> '[{"code":"aplus_missing_fact"}]';
  INSERT INTO _t SELECT 'gate: reports max_modules 5 standard', (gate->>'max_modules')::int = 5 AND (gate->>'premium')::boolean = false;
  -- module sạch: single_left_image đầy đủ
  m5 := '{"type":"standard_single_left_image","image":{"brief":"ảnh","url":""},"alt":"cốc gốm","headline":"Chất liệu","body":"Gốm men rạn 350 ml"}'::jsonb;
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5)), '[{"text":"350 ml","fact_id":null}]'::jsonb);
  INSERT INTO _t SELECT 'gate: clean module ok except unlinked claim (base rule)', (gate->'issues') @> '[{"code":"claim_no_fact"}]' OR (gate->>'ok')::boolean = true;
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: clean module passes', (gate->>'ok')::boolean = true;
  -- 6 module → block (Standard)
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5,m5,m5,m5,m5,m5)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: 6 modules blocked for Standard', (gate->'issues') @> '[{"code":"aplus_modules"}]';
  -- bật premium → 6 module ok, premium module ok
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.policy_register (tenant_id, aplus_premium_enabled) VALUES (t, true) ON CONFLICT (tenant_id) DO UPDATE SET aplus_premium_enabled = true;
  PERFORM pg_temp.as_user(u_op);
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5,m5,m5,m5,m5,m5)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: 6 modules ok with Premium', (gate->>'ok')::boolean = true AND (gate->>'max_modules')::int = 7;
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.policy_register SET aplus_premium_enabled = false WHERE tenant_id = t;
  PERFORM pg_temp.as_user(u_op);
  gate := public.check_content_compliance(t, sk1, 'aplus', '{"modules":[{"type":"premium_full_image","image":{"brief":"x","url":""},"alt":"a","headline":"h","body":"b"}]}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: premium module blocked w/o Premium', (gate->'issues') @> '[{"code":"aplus_premium"}]';
  -- giới hạn từng trường
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || jsonb_build_object('headline', repeat('x',161)))), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: headline 161 > 160 blocks', (gate->'issues') @> '[{"code":"aplus_len"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', '{"modules":[{"type":"standard_single_image_sidebar","image":{"brief":"x","url":""},"alt":"a","headline":"h","body":"' || repeat('b',501) || '"}]}', '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: sidebar body 501 > 500 blocks', (gate->'issues') @> '[{"code":"aplus_len"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || '{"alt":""}'::jsonb)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: missing alt → required block + alt warn', (gate->'issues') @> '[{"code":"aplus_alt","severity":"warn"}]' AND (gate->'issues') @> '[{"code":"aplus_required"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || '{"body":"Thiếu"}'::jsonb || '{"body":""}'::jsonb)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: required body missing blocks', (gate->'issues') @> '[{"code":"aplus_required"}]';
  -- tech specs > 16 dòng
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(jsonb_build_object('type','standard_tech_specs','headline','h','specs',(SELECT jsonb_agg(jsonb_build_object('name','n','value','v')) FROM generate_series(1,17))))), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: 17 spec rows blocks', (gate->'issues') @> '[{"code":"aplus_table_rows"}]';
  -- comparison: ASIN lạ block, ASIN cùng brand ok
  gate := public.check_content_compliance(t, sk1, 'aplus', '{"modules":[{"type":"standard_comparison_chart","products":[{"image":{"brief":"x","url":""},"alt":"a","asin":"B0TEST0018","title":"A"},{"image":{"brief":"x","url":""},"alt":"b","asin":"B0FOREIGN99","title":"B"}],"metrics":[{"name":"Dung tích","values":"350 ml | 500 ml"}]}]}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: foreign ASIN in comparison blocks', (gate->'issues') @> '[{"code":"aplus_comparison_foreign"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', '{"modules":[{"type":"standard_comparison_chart","products":[{"image":{"brief":"x","url":""},"alt":"a","asin":"B0TEST0018","title":"A"},{"image":{"brief":"x","url":""},"alt":"b","asin":"B0SIBLING18","title":"B"}],"metrics":[{"name":"Dung tích","values":"350 ml | 500 ml"}]}]}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: sibling ASIN comparison ok', (gate->>'ok')::boolean = true;
  gate := public.check_content_compliance(t, sk1, 'aplus', '{"modules":[{"type":"standard_comparison_chart","products":[{"image":{"brief":"x","url":""},"alt":"a","asin":"B0TEST0018","title":"A"}],"metrics":[]}]}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: comparison needs ≥ 2 products', (gate->'issues') @> '[{"code":"aplus_list_count"}]';
  -- nội dung cấm
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || '{"body":"Giảm giá 20% chỉ hôm nay"}'::jsonb)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: price/promo blocks', (gate->'issues') @> '[{"code":"aplus_price_promo"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || '{"body":"Liên hệ www.vexim.vn"}'::jsonb)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: external link blocks', (gate->'issues') @> '[{"code":"aplus_external"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || '{"body":"Best seller number one"}'::jsonb)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: absolute claim blocks', (gate->'issues') @> '[{"code":"aplus_claim"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus', jsonb_build_object('modules', jsonb_build_array(m5 || '{"headline":"Tốt hơn đối thủ"}'::jsonb)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: competitor in headline warns', (gate->'issues') @> '[{"code":"aplus_competitor"}]';
  -- gate cũ vẫn áp cho title; body cũ vẫn kiểm được
  gate := public.check_content_compliance(t, sk1, 'title', '{"text":"BEST SELLER bottle"}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: title base rules intact', (gate->>'ok')::boolean = false;
  gate := public.check_content_compliance(t, sk1, 'aplus', '{"modules":[{"type":"standard_image_text","header":"H","body":"Gốm","image_brief":"I"}]}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: legacy body evaluated via upgrade (needs alt)', (gate->'issues') @> '[{"code":"aplus_alt"}]' AND NOT ((gate->'issues') @> '[{"code":"aplus_type"}]');

  -- 5. Templates đều là module thật và ≤ 5
  INSERT INTO _t SELECT 'tpl: all global templates use real module types', NOT EXISTS (SELECT 1 FROM public.aplus_templates a, jsonb_array_elements(a.modules) m WHERE a.tenant_id IS NULL AND NOT EXISTS (SELECT 1 FROM public.aplus_module_specs s WHERE s.type = m->>'type'));
  INSERT INTO _t SELECT 'tpl: all global templates ≤ 5 modules', NOT EXISTS (SELECT 1 FROM public.aplus_templates WHERE tenant_id IS NULL AND jsonb_array_length(modules) > 5);
  PERFORM pg_temp.as_user(gen_random_uuid());
  PERFORM pg_temp.expect_error('build: outsider denied', format('SELECT public.build_aplus_from_template(%L, %L)', tpl, sk1));

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
