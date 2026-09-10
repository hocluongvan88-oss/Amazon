-- ============================================================
-- Test 017 — chạy trong SQL Editor SAU 017. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sk1 UUID; sku2 UUID; cv UUID; tpl UUID; tpl2 UUID; built JSONB; gate JSONB; n INT; d INT; rv UUID; fid UUID;
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
  INSERT INTO public.tenants (slug, name) VALUES ('t016', 'Test 017') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'owner'), (t, u_view, 'viewer');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
  VALUES (t, 'B0TEST0017', 'T-017', 'Bình nước', 'US', 30, 10, 5, 15, 0) RETURNING id INTO sk1;
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at) VALUES (t, 'B0TEST0017', 1, 'Leaks', 'Nắp bị rò', now()) RETURNING id INTO rv;

  -- Facts: material + capacity verified; warranty chỉ proposed
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.product_facts (tenant_id, sku_id, key, value, unit, source_type, source_ref) VALUES
    (t, sk1, 'material', 'Tritan BPA-free', NULL, 'supplier', 'spec-sheet.pdf'),
    (t, sk1, 'capacity', '750', 'ml', 'document', 'spec-sheet.pdf'),
    (t, sk1, 'warranty', '12 tháng', NULL, 'manual', NULL);
  UPDATE public.product_facts SET status = 'verified' WHERE tenant_id = t AND key IN ('material','capacity');

  -- 1. Template seed
  INSERT INTO _t SELECT 'tpl: 4 global templates', (SELECT count(*) FROM public.aplus_templates WHERE tenant_id IS NULL) = 4;
  SELECT id INTO tpl FROM public.aplus_templates WHERE tenant_id IS NULL AND key = 'launch_basic';

  -- 2. build_aplus_from_template
  PERFORM pg_temp.as_user(u_op);
  built := public.build_aplus_from_template(tpl, sk1);
  INSERT INTO _t SELECT 'build: 5 modules', jsonb_array_length(built->'body'->'modules') = 5;
  INSERT INTO _t SELECT 'build: capacity filled with unit', (built->'body'->'modules'->1->>'body') LIKE '%750 ml%';
  INSERT INTO _t SELECT 'build: material filled', (built->'body'->'modules'->1->>'body') LIKE '%Tritan BPA-free%';
  INSERT INTO _t SELECT 'build: title placeholder replaced', (built->'body'->'modules'->0->>'header') LIKE '%Bình nước%';
  INSERT INTO _t SELECT 'build: missing facts listed (dimensions, weight, warranty)', (built->'missing_facts') @> '["dimensions","weight","warranty"]'::jsonb AND NOT ((built->'missing_facts') @> '["capacity"]'::jsonb);
  INSERT INTO _t SELECT 'build: proposed fact NOT used', (built->'body'->'modules'->4->>'body') LIKE '%[warranty: CHƯA CÓ FACT]%';
  INSERT INTO _t SELECT 'build: claims linked to fact ids (2)', jsonb_array_length(built->'claims') = 2 AND (SELECT bool_and((c->>'fact_id') IS NOT NULL) FROM jsonb_array_elements(built->'claims') c);
  INSERT INTO _t SELECT 'build: brief mentions template + missing', (built->>'brief') LIKE '%launch%' AND (built->>'brief') LIKE '%thiếu fact%';

  -- 3. Gate A+: placeholder chưa điền → block; sau khi bỏ module thiếu → pass (warn image brief)
  gate := public.check_content_compliance(t, sk1, 'aplus', built->'body', built->'claims');
  INSERT INTO _t SELECT 'gate: missing-fact placeholder blocks', (gate->>'ok')::boolean = false AND (gate->'issues') @> '[{"code":"aplus_missing_fact"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus',
    jsonb_build_object('modules', jsonb_build_array(built->'body'->'modules'->0, built->'body'->'modules'->1)), built->'claims');
  INSERT INTO _t SELECT 'gate: clean modules pass', (gate->>'ok')::boolean = true;
  gate := public.check_content_compliance(t, sk1, 'aplus',
    jsonb_build_object('modules', jsonb_build_array(jsonb_build_object('type','standard_image_text','header', repeat('x', 170),'body','ok','image_brief',''))), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: header > 160 blocks', (gate->'issues') @> '[{"code":"aplus_header_len"}]';
  INSERT INTO _t SELECT 'gate: empty image brief warns', (gate->'issues') @> '[{"code":"aplus_image_brief","severity":"warn"}]';
  gate := public.check_content_compliance(t, sk1, 'aplus',
    jsonb_build_object('modules', jsonb_build_array(jsonb_build_object('type','standard_text','header','So sánh','body','Tốt hơn đối thủ','image_brief',''))), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: competitor mention warns', (gate->'issues') @> '[{"code":"aplus_competitor"}]';
  -- gate cũ (013) vẫn chạy cho kind khác
  gate := public.check_content_compliance(t, sk1, 'title', '{"text":"BEST SELLER bottle"}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: base rules still apply for title', (gate->>'ok')::boolean = false;

  -- 4. Template theo tenant: operator không tạo được; owner (content.qa_approve) tạo được; tenant khác không thấy
  -- SQL Editor chạy với role postgres (bypass RLS) → kiểm policy + permission thay vì insert trực tiếp
  INSERT INTO _t SELECT 'tpl: write policy requires content.qa_approve', EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'aplus_templates' AND policyname = 'tpl_write' AND qual LIKE '%content.qa_approve%');
  INSERT INTO _t SELECT 'tpl: operator lacks content.qa_approve', public.has_permission(t, 'content.qa_approve') = false;
  PERFORM pg_temp.as_user(u_qa);
  INSERT INTO _t SELECT 'tpl: owner has content.qa_approve', public.has_permission(t, 'content.qa_approve') = true;
  PERFORM pg_temp.expect_ok('tpl: owner creates tenant template', format('INSERT INTO public.aplus_templates (tenant_id, key, name, use_case, modules) VALUES (%L, ''mine'', ''Riêng'', ''trust'', ''[{"type":"standard_text","header":"{brand}","body":"{fact:capacity}","image_brief":""}]''::jsonb)', t));
  SELECT id INTO tpl2 FROM public.aplus_templates WHERE tenant_id = t AND key = 'mine';
  built := public.build_aplus_from_template(tpl2, sk1);
  INSERT INTO _t SELECT 'tpl: tenant template builds', (built->'body'->'modules'->0->>'body') = '750 ml';
  INSERT INTO _t SELECT 'audit: tenant template logged', EXISTS (SELECT 1 FROM public.audit_log WHERE entity_type = 'aplus_templates' AND tenant_id = t);
  PERFORM pg_temp.as_user(gen_random_uuid());
  PERFORM pg_temp.expect_error('build: outsider denied', format('SELECT public.build_aplus_from_template(%L, %L)', tpl, sk1));

  -- 5. content_cvr_series: publish 10 ngày trước, 30 ngày dữ liệu, 1 ASIN đối chứng
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
    VALUES (t, 'B0CTRL00172', 'C-2', 'Đối chứng', 'US', 30, 10, 5, 15, 500) RETURNING id INTO sku2;
  FOR d IN 1..30 LOOP
    INSERT INTO public.sku_daily_snapshots (sku_id, tenant_id, asin, date, units, revenue, sessions, ad_spend, price, contribution_profit, inventory_qty) VALUES
      (sk1,  t, 'B0TEST0017', CURRENT_DATE - d, CASE WHEN d < 10 THEN 10 ELSE 5 END, 300, 100, 10, 30, 10, 500),
      (sku2, t, 'B0CTRL00172', CURRENT_DATE - d, 5, 150, 100, 10, 30, 10, 500);
  END LOOP;
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body, created_by) VALUES (t, sk1, 'aplus', '{"modules":[{"type":"standard_text","header":"h","body":"b","image_brief":""}]}'::jsonb, u_op) RETURNING id INTO cv;
  UPDATE public.content_versions SET status = 'qa_review' WHERE id = cv;
  UPDATE public.content_versions SET status = 'qa_passed' WHERE id = cv;
  UPDATE public.content_versions SET status = 'awaiting_brand_approval' WHERE id = cv;
  UPDATE public.content_versions SET status = 'approved', brand_by = u_qa, brand_at = now() WHERE id = cv;
  UPDATE public.content_versions SET status = 'published' WHERE id = cv;
  UPDATE public.content_versions SET published_at = now() - interval '10 days' WHERE id = cv;
  PERFORM pg_temp.as_user(u_op);
  SELECT count(*) INTO n FROM public.content_cvr_series(cv, 14);
  INSERT INTO _t SELECT 'series: rows = 14 before + publish + 10 after = 25', n = 25;
  INSERT INTO _t SELECT 'series: phases labelled', (SELECT count(DISTINCT phase) FROM public.content_cvr_series(cv, 14)) = 3;
  INSERT INTO _t SELECT 'series: cvr before 5%, after 10%', (SELECT avg(cvr) FILTER (WHERE phase='before') = 0.05 AND avg(cvr) FILTER (WHERE phase='after') = 0.10 FROM public.content_cvr_series(cv, 14));
  INSERT INTO _t SELECT 'series: control cvr flat 5%', (SELECT min(control_cvr) = 0.05 AND max(control_cvr) = 0.05 FROM public.content_cvr_series(cv, 14) WHERE control_cvr IS NOT NULL);
  PERFORM pg_temp.as_user(gen_random_uuid());
  PERFORM pg_temp.expect_error('series: outsider denied', format('SELECT count(*) FROM public.content_cvr_series(%L, 14)', cv));

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
