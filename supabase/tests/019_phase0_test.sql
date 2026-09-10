-- ============================================================
-- Test 019 — chạy trong SQL Editor SAU 019. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sk1 UUID; rec UUID; a public.actions; v1 UUID; pr public.publish_records; fact UUID; n INT; rv UUID; h JSONB;
  u_op UUID := gen_random_uuid(); u_qa UUID := gen_random_uuid(); u_view UUID := gen_random_uuid(); u_brand UUID := gen_random_uuid(); u_lead UUID := gen_random_uuid(); u UUID;
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

  FOREACH u IN ARRAY ARRAY[u_op,u_qa,u_view,u_brand,u_lead] LOOP
    INSERT INTO auth.users (id, email, instance_id, aud, role, encrypted_password, created_at, updated_at)
    VALUES (u, u::text || '@test.local', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), now());
  END LOOP;
  INSERT INTO public.tenants (slug, name) VALUES ('t018', 'Test 019') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'owner'), (t, u_view, 'viewer'), (t, u_brand, 'brand_approver'), (t, u_lead, 'ops_lead');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
  VALUES (t, 'B0TEST0019', 'T-019', 'Bình nước', 'US', 30, 10, 5, 15, 0) RETURNING id INTO sk1;
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at) VALUES (t, 'B0TEST0019', 1, 'Leaks', 'Nắp bị rò', now()) RETURNING id INTO rv;

  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.sku_daily_snapshots (sku_id, date, tenant_id, asin, units, revenue) SELECT sk1, CURRENT_DATE - g, t, 'B0TEST0019', 5, 150 FROM generate_series(0,6) g;
  UPDATE public.policy_register SET canary_asins = ARRAY['B0TEST0019'], automation_live = true, max_automation_level = 'L4' WHERE tenant_id = t;

  -- 0. Schema / security
  INSERT INTO _t SELECT 'schema: actions.execution_channel + amazon_applied', (SELECT count(*) FROM information_schema.columns WHERE table_name='actions' AND column_name IN ('execution_channel','amazon_applied')) = 2;
  INSERT INTO _t SELECT 'schema: publish_records exists + RLS', to_regclass('public.publish_records') IS NOT NULL AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.publish_records'::regclass);
  INSERT INTO _t SELECT 'schema: publish_records no write policy (RPC only)', NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'publish_records' AND cmd <> 'SELECT');
  INSERT INTO _t SELECT 'security: 0 SECURITY DEFINER without search_path', (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname='public' AND p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%')) = 0;
  INSERT INTO _t SELECT 'policy: publish_evidence_required default true', (SELECT publish_evidence_required FROM public.policy_register WHERE tenant_id = t);

  -- 1. Action semantics: canary = ghi nhận nội bộ, không false-success
  PERFORM pg_temp.as_user(u_qa);
  INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, current_value, proposed_value, risk_score, approval_tier, status)
  VALUES (t, sk1, 'B0TEST0019', 'price_adjust', 'P0 test', 30, 30.5, 10, 'L0', 'draft') RETURNING id INTO rec;
  UPDATE public.recommendations SET status = 'pending_approval' WHERE id = rec;
  PERFORM pg_temp.as_user(u_op);
  UPDATE public.recommendations SET status = 'approved' WHERE id = rec;
  a := public.execute_recommendation(rec, 'dry_run');
  INSERT INTO _t SELECT 'action: dry_run succeeded + simulated + no submission_id', a.status = 'succeeded' AND (a.response->>'simulated')::boolean AND NOT (a.response ? 'submission_id') AND a.amazon_applied = false;
  PERFORM pg_temp.expect_error('action: live blocked without sp_api', format('SELECT public.execute_recommendation(%L, ''live'')', rec));
  a := public.execute_recommendation(rec, 'canary');
  INSERT INTO _t SELECT 'action: canary → internal_record, amazon_applied=false, no submission_id', a.status = 'succeeded' AND a.execution_channel = 'internal_record' AND a.amazon_applied = false AND NOT (a.response ? 'submission_id') AND a.response->>'channel' = 'internal_record';
  INSERT INTO _t SELECT 'action: automation_level stays L3 for canary', a.automation_level = 'L3';
  INSERT INTO _t SELECT 'action: internal price updated in DB only', (SELECT current_price FROM public.amazon_skus WHERE id = sk1) = 30.5;
  PERFORM pg_temp.expect_error('action: manual confirm needs evidence', format('SELECT public.confirm_manual_execution(%L, ''x'')', a.id));
  PERFORM pg_temp.as_user(u_view);
  PERFORM pg_temp.expect_error('action: viewer cannot confirm manual', format('SELECT public.confirm_manual_execution(%L, ''https://sellercentral.amazon.com/x'')', a.id));
  PERFORM pg_temp.as_user(u_op);
  a := public.confirm_manual_execution(a.id, 'https://sellercentral.amazon.com/inventory?asin=B0TEST0019');
  INSERT INTO _t SELECT 'action: manual confirm → manual_seller_central + amazon_applied', a.execution_channel = 'manual_seller_central' AND a.amazon_applied AND a.manual_confirmed_by = u_op;
  PERFORM pg_temp.expect_error('action: cannot confirm twice', format('SELECT public.confirm_manual_execution(%L, ''https://x.y/again'')', a.id));
  INSERT INTO _t SELECT 'stats: internal_records / amazon_applied columns', (SELECT amazon_applied = 1 FROM public.v_automation_stats WHERE tenant_id = t);
  INSERT INTO _t SELECT 'audit: action confirm logged', EXISTS (SELECT 1 FROM public.audit_log WHERE tenant_id = t AND entity_id = a.id);
  INSERT INTO _t SELECT 'health: system_health returns known status', (public.system_health()->>'cron_status') IN ('ok','missing','unknown') AND (public.system_health()->>'write_back_enabled')::boolean = false;
  -- sp_api connected → live không còn bị chặn bởi kiểm tra kênh (nhưng kênh chưa triển khai → failed, không succeeded)
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.data_sources (tenant_id, kind, name, status, feeds) VALUES (t, 'sp_api', 'test', 'connected', '{}');
  PERFORM pg_temp.as_user(u_op);
  UPDATE public.recommendations SET status = 'approved' WHERE id = rec; -- đã executed → không đổi; tạo rec mới
  PERFORM pg_temp.as_user(u_qa);
  INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, current_value, proposed_value, risk_score, approval_tier, status)
  VALUES (t, sk1, 'B0TEST0019', 'price_adjust', 'P0 live test', 30.5, 30.8, 10, 'L0', 'draft') RETURNING id INTO rec;
  UPDATE public.recommendations SET status = 'pending_approval' WHERE id = rec;
  PERFORM pg_temp.as_user(u_op);
  UPDATE public.recommendations SET status = 'approved' WHERE id = rec;
  PERFORM public.execute_recommendation(rec, 'dry_run');
  a := public.execute_recommendation(rec, 'live');
  INSERT INTO _t SELECT 'action: live with sp_api → channel sp_api, failed (not implemented), never succeeded', a.execution_channel = 'sp_api' AND a.status = 'failed' AND a.amazon_applied = false;
  INSERT INTO _t SELECT 'action: failed live does not mark rec executed', (SELECT status FROM public.recommendations WHERE id = rec) = 'approved';

  -- 2. Publish evidence
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.product_facts (tenant_id, sku_id, key, value, unit, source_type, source_ref) VALUES (t, sk1, 'capacity', '750', 'ml', 'document', 'spec.pdf') RETURNING id INTO fact;
  UPDATE public.product_facts SET status = 'verified' WHERE id = fact;
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body, claims) VALUES (t, sk1, 'title', '{"text":"Tritan Water Bottle 750 ml"}'::jsonb, jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', fact))) RETURNING id INTO v1;
  UPDATE public.content_versions SET status = 'qa_review' WHERE id = v1;
  PERFORM pg_temp.as_user(u_qa);
  UPDATE public.content_versions SET status = 'qa_passed' WHERE id = v1;
  UPDATE public.content_versions SET status = 'awaiting_brand_approval' WHERE id = v1;
  PERFORM pg_temp.as_user(u_brand);
  PERFORM pg_temp.expect_error('publish: record_publish blocked before approved', format('SELECT public.record_publish(%L, ''https://amazon.com/dp/B0TEST0019'')', v1));
  UPDATE public.content_versions SET status = 'approved' WHERE id = v1;
  PERFORM pg_temp.expect_error('publish: direct UPDATE to published blocked (evidence required)', format('UPDATE public.content_versions SET status = ''published'' WHERE id = %L', v1));
  PERFORM pg_temp.expect_error('publish: record_publish without evidence blocked', format('SELECT public.record_publish(%L, NULL, ''ok'')', v1));
  PERFORM pg_temp.expect_error('publish: bad URL blocked', format('SELECT public.record_publish(%L, ''ftp://x'')', v1));
  PERFORM pg_temp.as_user(u_view);
  PERFORM pg_temp.expect_error('publish: viewer cannot record_publish', format('SELECT public.record_publish(%L, ''https://amazon.com/dp/B0TEST0019'')', v1));
  PERFORM pg_temp.as_user(u_brand);
  pr := public.record_publish(v1, 'https://www.amazon.com/dp/B0TEST0019', 'Đã sửa title lúc 10:00');
  INSERT INTO _t SELECT 'publish: record created manual_verified', pr.kind = 'publish' AND pr.channel = 'manual' AND pr.verify_status = 'manual_verified' AND pr.performed_by = u_brand;
  INSERT INTO _t SELECT 'publish: version → published with publish_channel', (SELECT status = 'published' AND publish_channel = 'seller_central_manual' AND published_by = u_brand FROM public.content_versions WHERE id = v1);
  INSERT INTO _t SELECT 'audit: publish_records logged', EXISTS (SELECT 1 FROM public.audit_log WHERE tenant_id = t AND entity_id = pr.id);
  PERFORM pg_temp.expect_error('rollback: needs reason', format('SELECT public.record_rollback(%L, '''')', v1));
  pr := public.record_rollback(v1, 'Sai thông số, đã khôi phục bản cũ');
  INSERT INTO _t SELECT 'rollback: record + version rolled_back', pr.kind = 'rollback' AND (SELECT status = 'rolled_back' AND rollback_reason LIKE 'Sai%' FROM public.content_versions WHERE id = v1);
  -- policy tắt → UPDATE trực tiếp được (tương thích test cũ / môi trường thử)
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.policy_register SET publish_evidence_required = false WHERE tenant_id = t;
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body, claims) VALUES (t, sk1, 'title', '{"text":"Tritan Water Bottle 750 ml v2"}'::jsonb, jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', fact))) RETURNING id INTO v1;
  UPDATE public.content_versions SET status = 'qa_review' WHERE id = v1;
  PERFORM pg_temp.as_user(u_qa); UPDATE public.content_versions SET status = 'qa_passed' WHERE id = v1; UPDATE public.content_versions SET status = 'awaiting_brand_approval' WHERE id = v1;
  PERFORM pg_temp.as_user(u_brand); UPDATE public.content_versions SET status = 'approved' WHERE id = v1;
  PERFORM pg_temp.expect_ok('publish: policy off → direct publish allowed', format('UPDATE public.content_versions SET status = ''published'' WHERE id = %L', v1));

  -- 3. SoD vẫn nguyên: ops_lead (có content.qa_approve, không có policy.override) tự soạn rồi tự QA → lỗi
  PERFORM pg_temp.as_user(u_lead);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body, claims) VALUES (t, sk1, 'bullets', '{"items":["Tritan 750 ml"]}'::jsonb, jsonb_build_array(jsonb_build_object('text','750 ml','fact_id', fact))) RETURNING id INTO v1;
  UPDATE public.content_versions SET status = 'qa_review' WHERE id = v1;
  PERFORM pg_temp.expect_error('SoD: author cannot self-QA', format('UPDATE public.content_versions SET status = ''qa_passed'' WHERE id = %L', v1));

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
