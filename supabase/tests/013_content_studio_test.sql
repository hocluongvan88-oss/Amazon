-- ============================================================
-- Test 013 — chạy trong SQL Editor SAU 013. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sku UUID; fact UUID; v1 UUID; v2 UUID; c JSONB; st TEXT;
  u_op UUID := gen_random_uuid(); u_qa UUID := gen_random_uuid(); u_brand UUID := gen_random_uuid(); u_lead UUID := gen_random_uuid(); u UUID;
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

  FOREACH u IN ARRAY ARRAY[u_op,u_qa,u_brand,u_lead] LOOP
    INSERT INTO auth.users (id, email, instance_id, aud, role, encrypted_password, created_at, updated_at)
    VALUES (u, u::text || '@test.local', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), now());
  END LOOP;
  INSERT INTO public.tenants (slug, name) VALUES ('t013', 'Test 013') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'content_qa'), (t, u_brand, 'brand_approver'), (t, u_lead, 'ops_lead');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct)
  VALUES (t, 'B0TEST0013', 'T-013', 'Bình nước Tritan', 'US', 30, 10, 5, 15) RETURNING id INTO sku;

  -- 1. Facts: operator đề xuất, không tự verify; QA verify cần source_ref
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.product_facts (tenant_id, sku_id, key, value, unit, source_type, source_ref) VALUES (t, sku, 'capacity', '750', 'ml', 'document', 'spec-sheet-v3.pdf') RETURNING id INTO fact;
  PERFORM pg_temp.expect_error('fact: proposer cannot self-verify', format('UPDATE public.product_facts SET status=''verified'' WHERE id=%L', fact));
  PERFORM pg_temp.as_user(u_qa);
  PERFORM pg_temp.expect_ok('fact: qa verifies', format('UPDATE public.product_facts SET status=''verified'' WHERE id=%L', fact));
  PERFORM pg_temp.expect_error('fact: verified is immutable', format('UPDATE public.product_facts SET value=''800'' WHERE id=%L', fact));
  -- fact document không có source_ref → không verify được
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.product_facts (tenant_id, sku_id, key, value, source_type) VALUES (t, sku, 'material', 'Tritan', 'document') RETURNING id INTO u;
  PERFORM pg_temp.as_user(u_qa);
  PERFORM pg_temp.expect_error('fact: verify requires source_ref', format('UPDATE public.product_facts SET status=''verified'' WHERE id=%L', u));

  -- 2. Compliance gate
  c := public.check_content_compliance(t, sku, 'title', '{"text":"Best Seller Water Bottle"}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: banned term blocked', NOT (c->>'ok')::boolean AND c->'issues' @> '[{"code":"banned_term"}]';
  c := public.check_content_compliance(t, sku, 'title', '{"text":"TRITAN WATER BOTTLE WITH LID"}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: all-caps title blocked', NOT (c->>'ok')::boolean AND c->'issues' @> '[{"code":"title_caps"}]';
  c := public.check_content_compliance(t, sku, 'title', '{"text":"Water Bottle! Buy now?"}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: forbidden chars blocked', c->'issues' @> '[{"code":"title_chars"}]';
  c := public.check_content_compliance(t, sku, 'title', '{"text":"Tritan Water Bottle 750 ml, Leak-proof Lid"}'::jsonb, jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', fact)));
  INSERT INTO _t SELECT 'gate: clean title with claim→fact passes', (c->>'ok')::boolean;
  c := public.check_content_compliance(t, sku, 'title', '{"text":"Water Bottle 750 ml"}'::jsonb, jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', NULL)));
  INSERT INTO _t SELECT 'gate: claim without fact blocked', NOT (c->>'ok')::boolean;
  c := public.check_content_compliance(t, sku, 'bullets', jsonb_build_object('items', jsonb_build_array('a','b','c','d','e','f')), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: >5 bullets blocked', NOT (c->>'ok')::boolean;
  c := public.check_content_compliance(t, sku, 'backend_keywords', jsonb_build_object('text', repeat('keyword ', 40)), '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: backend >249 bytes blocked', NOT (c->>'ok')::boolean;
  c := public.check_content_compliance(t, sku, 'aplus', '{"modules":[{"type":"bogus","header":"x","body":"y"}]}'::jsonb, '[]'::jsonb);
  INSERT INTO _t SELECT 'gate: invalid A+ module type blocked', NOT (c->>'ok')::boolean;

  -- 3. State machine + SoD
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body, claims) VALUES (t, sku, 'title', '{"text":"BEST SELLER bottle"}'::jsonb, '[]'::jsonb) RETURNING id INTO v1;
  INSERT INTO _t SELECT 'cv: version auto = 1', (SELECT version = 1 FROM public.content_versions WHERE id = v1);
  PERFORM pg_temp.expect_error('cv: gate blocks qa_review', format('UPDATE public.content_versions SET status=''qa_review'' WHERE id=%L', v1));
  -- sửa nội dung hợp lệ → gate đạt
  UPDATE public.content_versions SET body = '{"text":"Tritan Water Bottle 750 ml, Leak-proof Lid"}'::jsonb, claims = jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', fact)) WHERE id = v1;
  INSERT INTO _t SELECT 'cv: gate recomputed ok', (SELECT (compliance->>'ok')::boolean FROM public.content_versions WHERE id = v1);
  PERFORM pg_temp.expect_ok('cv: draft→qa_review', format('UPDATE public.content_versions SET status=''qa_review'' WHERE id=%L', v1));
  PERFORM pg_temp.expect_error('cv: operator cannot QA', format('UPDATE public.content_versions SET status=''qa_passed'' WHERE id=%L', v1));
  PERFORM pg_temp.expect_error('cv: cannot skip to published', format('UPDATE public.content_versions SET status=''published'' WHERE id=%L', v1));
  PERFORM pg_temp.as_user(u_qa);
  PERFORM pg_temp.expect_ok('cv: qa passes', format('UPDATE public.content_versions SET status=''qa_passed'' WHERE id=%L', v1));
  PERFORM pg_temp.expect_ok('cv: →awaiting_brand', format('UPDATE public.content_versions SET status=''awaiting_brand_approval'' WHERE id=%L', v1));
  PERFORM pg_temp.expect_error('cv: qa cannot brand-approve', format('UPDATE public.content_versions SET status=''approved'' WHERE id=%L', v1));
  PERFORM pg_temp.as_user(u_lead);
  PERFORM pg_temp.expect_error('cv: ops_lead without delegation cannot brand-approve', format('UPDATE public.content_versions SET status=''approved'' WHERE id=%L', v1));
  PERFORM pg_temp.as_user(u_brand);
  PERFORM pg_temp.expect_ok('cv: brand approves', format('UPDATE public.content_versions SET status=''approved'' WHERE id=%L', v1));
  PERFORM pg_temp.expect_error('cv: cannot edit approved body', format('UPDATE public.content_versions SET body=''{"text":"x"}'' WHERE id=%L', v1));
  PERFORM pg_temp.as_user(u_qa);
  PERFORM pg_temp.expect_error('cv: qa cannot publish', format('UPDATE public.content_versions SET status=''published'' WHERE id=%L', v1));
  PERFORM pg_temp.as_user(u_brand);
  PERFORM pg_temp.expect_ok('cv: brand records publish', format('UPDATE public.content_versions SET status=''published'' WHERE id=%L', v1));
  INSERT INTO _t SELECT 'cv: publish_channel default manual', (SELECT publish_channel = 'seller_central_manual' AND published_by = u_brand FROM public.content_versions WHERE id = v1);

  -- 4. Version 2 thay thế → v1 superseded; rollback cần lý do
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, parent_id, body, claims) VALUES (t, sku, 'title', v1, '{"text":"Tritan Water Bottle 750 ml with Carry Loop"}'::jsonb, jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', fact))) RETURNING id INTO v2;
  INSERT INTO _t SELECT 'cv: version auto = 2', (SELECT version = 2 FROM public.content_versions WHERE id = v2);
  UPDATE public.content_versions SET status='qa_review' WHERE id = v2;
  PERFORM pg_temp.as_user(u_qa);   UPDATE public.content_versions SET status='qa_passed' WHERE id = v2; UPDATE public.content_versions SET status='awaiting_brand_approval' WHERE id = v2;
  PERFORM pg_temp.as_user(u_brand); UPDATE public.content_versions SET status='approved' WHERE id = v2; UPDATE public.content_versions SET status='published' WHERE id = v2;
  INSERT INTO _t SELECT 'cv: old published → superseded', (SELECT status = 'superseded' FROM public.content_versions WHERE id = v1);
  PERFORM pg_temp.expect_error('cv: rollback needs reason', format('UPDATE public.content_versions SET status=''rolled_back'' WHERE id=%L', v2));
  PERFORM pg_temp.expect_ok('cv: rollback with reason', format('UPDATE public.content_versions SET status=''rolled_back'', rollback_reason=''CVR giảm 15%%'' WHERE id=%L', v2));

  -- 5. Delegation: brand uỷ quyền cho ops_lead → lead duyệt được
  PERFORM pg_temp.as_user(u_brand);
  PERFORM public.grant_delegation(t, u_lead::text || '@test.local', 'content.brand_approve', 'Brand nghỉ phép', 7);
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body) VALUES (t, sku, 'description', '{"text":"Durable Tritan bottle for daily use."}'::jsonb) RETURNING id INTO u;
  UPDATE public.content_versions SET status='qa_review' WHERE id = u;
  PERFORM pg_temp.as_user(u_qa); UPDATE public.content_versions SET status='qa_passed' WHERE id = u; UPDATE public.content_versions SET status='awaiting_brand_approval' WHERE id = u;
  PERFORM pg_temp.as_user(u_lead);
  PERFORM pg_temp.expect_ok('cv: delegated lead brand-approves', format('UPDATE public.content_versions SET status=''approved'' WHERE id=%L', u));

  -- 6. Audit & impact
  INSERT INTO _t SELECT 'audit: content_versions logged', EXISTS (SELECT 1 FROM public.audit_log WHERE entity_type='content_versions' AND entity_id = v1);
  INSERT INTO _t SELECT 'impact: insufficient data reported honestly', (SELECT (public.content_impact(v2, 14)->>'confidence') = 'insufficient_data');
  INSERT INTO _t SELECT 'audit view: sku listed', EXISTS (SELECT 1 FROM public.v_listing_audit WHERE sku_id = sku);

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
