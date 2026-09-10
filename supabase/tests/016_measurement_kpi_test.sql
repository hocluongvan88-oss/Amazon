-- ============================================================
-- Test 016 — chạy trong SQL Editor SAU 016. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sk1 UUID; sku2 UUID; sku3 UUID; act UUID; act2 UUID; cv UUID; m public.measurements; kp JSONB; sc JSONB; n INT; d INT; rv UUID;
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
  INSERT INTO public.tenants (slug, name) VALUES ('t016', 'Test 016') RETURNING id INTO t;
  -- 019: test này publish bằng UPDATE trực tiếp → tắt yêu cầu bằng chứng cho tenant test (nếu cột đã tồn tại)
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='policy_register' AND column_name='publish_evidence_required') THEN
    UPDATE public.policy_register SET publish_evidence_required = false WHERE tenant_id = t;
  END IF;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'owner'), (t, u_view, 'viewer');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
  VALUES (t, 'B0TEST0016', 'T-016', 'Bình nước', 'US', 30, 10, 5, 15, 0) RETURNING id INTO sk1;
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at) VALUES (t, 'B0TEST0016', 1, 'Leaks', 'Nắp bị rò', now()) RETURNING id INTO rv;

  -- Dữ liệu: 3 ASIN, 60 ngày. sk1 = ASIN tác động (CP tăng sau ngày -20); sku2/sku3 = đối chứng ổn định
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty) VALUES
    (t, 'B0CTRL00162', 'C-2', 'Đối chứng 2', 'US', 30, 10, 5, 15, 500) RETURNING id INTO sku2;
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty) VALUES
    (t, 'B0CTRL00163', 'C-3', 'Đối chứng 3', 'US', 30, 10, 5, 15, 500) RETURNING id INTO sku3;
  UPDATE public.amazon_skus SET inventory_qty = 500 WHERE id = sk1;
  FOR d IN 1..60 LOOP
    INSERT INTO public.sku_daily_snapshots (sku_id, tenant_id, asin, date, units, revenue, sessions, ad_spend, price, contribution_profit, inventory_qty) VALUES
      (sk1,  t, 'B0TEST0016', CURRENT_DATE - d, CASE WHEN d < 20 THEN 10 ELSE 5 END, 300, 100, 10, 30, 10, 500),
      (sku2, t, 'B0CTRL00162', CURRENT_DATE - d, 6, 180, 100, 10, 30, 10, 500),
      (sku3, t, 'B0CTRL00163', CURRENT_DATE - d, 6, 180, 100, 10, 30, 10, 500);
  END LOOP;
  -- feed orders "tươi" để không bị insufficient_data
  INSERT INTO public.ingestion_runs (tenant_id, feed_key, status, rows_total, rows_ok) VALUES (t, 'orders_daily', 'succeeded', 60, 60);
  -- action thật kết thúc 20 ngày trước (test seed: bật ngữ cảnh guard của 010; app không bao giờ làm vậy)
  PERFORM set_config('vexim.action_ctx', 'on', true);
  INSERT INTO public.actions (tenant_id, sku_id, asin, action_type, mode, idempotency_key, payload, status, finished_at, created_by)
    VALUES (t, sk1, 'B0TEST0016', 'price_update', 'live', 'k016-1', '{}'::jsonb, 'succeeded', now() - interval '20 days', u_op) RETURNING id INTO act;

  -- 1. measure_subject: action có đối chứng → CP tăng, không confounder → confidence high (CI không chứa 0 vì dữ liệu phẳng)
  PERFORM pg_temp.as_user(u_op);
  m := public.measure_subject('action', act, 14);
  INSERT INTO _t SELECT 'measure: row written', m.id IS NOT NULL AND m.subject_type = 'action';
  INSERT INTO _t SELECT 'measure: baseline frozen json has cp_per_day 50', (m.baseline->>'cp_per_day')::numeric = 50;
  INSERT INTO _t SELECT 'measure: observed cp_per_day 100', (m.observed->>'cp_per_day')::numeric = 100;
  INSERT INTO _t SELECT 'measure: control n=2, change 0%', (m.control->>'n')::int = 2 AND (m.control->>'change_pct')::numeric = 0;
  INSERT INTO _t SELECT 'measure: incremental +50/day', m.incremental_cp_per_day = 50;
  INSERT INTO _t SELECT 'measure: no concurrent changes', jsonb_array_length(m.concurrent_changes) = 0;
  INSERT INTO _t SELECT 'measure: confidence high', m.confidence = 'high';
  INSERT INTO _t SELECT 'measure: data_quality orders_fresh', (m.data_quality->>'orders_fresh')::boolean;
  INSERT INTO _t SELECT 'measure: not final yet', m.is_final = false;
  PERFORM pg_temp.expect_error('measure: bad window rejected', format('SELECT public.measure_subject(''action'', %L, 10)', act));
  PERFORM pg_temp.expect_error('measure: attributable_share cannot be set', format('UPDATE public.measurements SET attributable_share = 0.5 WHERE id = %L', m.id));

  -- 2. Thay đổi đồng thời → confounded, không chia attribution
  INSERT INTO public.actions (tenant_id, sku_id, asin, action_type, mode, idempotency_key, payload, status, finished_at, created_by)
    VALUES (t, sk1, 'B0TEST0016', 'price_update', 'live', 'k016-2', '{}'::jsonb, 'succeeded', now() - interval '15 days', u_op) RETURNING id INTO act2;
  m := public.measure_subject('action', act, 14);
  INSERT INTO _t SELECT 'confounded: re-measure updates same row', (SELECT count(*) FROM public.measurements WHERE subject_id = act AND window_days = 14) = 1;
  INSERT INTO _t SELECT 'confounded: concurrent action detected', m.concurrent_changes @> '[{"type":"action"}]';
  INSERT INTO _t SELECT 'confounded: confidence = confounded', m.confidence = 'confounded';
  INSERT INTO _t SELECT 'confounded: attributable_share NULL', m.attributable_share IS NULL;

  -- 3. Content version publish → measurable, cvr delta
  -- không có uid → trigger bỏ qua kiểm tra quyền/gate (test chỉ cần bản published có mốc thời gian)
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO public.content_versions (tenant_id, sku_id, kind, body, created_by) VALUES (t, sk1, 'title', '{"text":"Tritan bottle 750 ml"}'::jsonb, u_op) RETURNING id INTO cv;
  UPDATE public.content_versions SET status = 'qa_review' WHERE id = cv;
  UPDATE public.content_versions SET status = 'qa_passed' WHERE id = cv;
  UPDATE public.content_versions SET status = 'awaiting_brand_approval' WHERE id = cv;
  UPDATE public.content_versions SET status = 'approved', brand_by = u_qa, brand_at = now() WHERE id = cv;
  UPDATE public.content_versions SET status = 'published' WHERE id = cv;
  UPDATE public.content_versions SET published_at = now() - interval '20 days', qa_at = now() - interval '25 days', created_at = now() - interval '26 days' WHERE id = cv;
  PERFORM pg_temp.as_user(u_op);
  m := public.measure_subject('content_version', cv, 14);
  INSERT INTO _t SELECT 'content: measured', m.subject_type = 'content_version' AND m.cvr_delta_pct IS NOT NULL;
  INSERT INTO _t SELECT 'content: cvr +100%', m.cvr_delta_pct = 100;
  INSERT INTO _t SELECT 'content: confounded by concurrent actions', m.confidence = 'confounded';
  -- action đo lại giờ phải thấy content publish là confounder
  m := public.measure_subject('action', act, 14);
  INSERT INTO _t SELECT 'action: content publish counted as confounder', m.concurrent_changes @> '[{"type":"content"}]';

  -- 4. measure_all + finalize (chưa đủ 28 ngày sau cửa sổ → 0 final)
  SELECT public.measure_all(t, 14) INTO n;
  INSERT INTO _t SELECT 'measure_all: covers 3 subjects', n = 3;
  SELECT public.finalize_measurements(t) INTO n;
  INSERT INTO _t SELECT 'finalize: none yet (window+28d not passed)', n = 0;
  -- giả lập đã đủ tuổi
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.actions SET finished_at = now() - interval '50 days' WHERE id = act2;
  PERFORM pg_temp.as_user(u_op);
  PERFORM public.measure_subject('action', act2, 14);
  SELECT public.finalize_measurements(t) INTO n;
  INSERT INTO _t SELECT 'finalize: aged row finalized', n >= 1 AND (SELECT is_final FROM public.measurements WHERE subject_id = act2);
  PERFORM pg_temp.expect_error('final: numbers immutable', format('UPDATE public.measurements SET incremental_cp_total = 999 WHERE subject_id = %L', act2));
  PERFORM pg_temp.expect_ok('final: note editable', format('UPDATE public.measurements SET note = ''ghi chú'' WHERE subject_id = %L', act2));
  m := public.measure_subject('action', act2, 14);
  INSERT INTO _t SELECT 'final: re-measure returns frozen row', m.is_final;

  -- 5. KPI content / AI / scorecard v2
  kp := public.content_kpi(t, 60);
  INSERT INTO _t SELECT 'content_kpi: published=1', (kp->>'published')::int = 1;
  INSERT INTO _t SELECT 'content_kpi: hours_draft_to_publish ≈ 144', (kp->>'hours_draft_to_publish')::numeric BETWEEN 140 AND 148;
  INSERT INTO _t SELECT 'content_kpi: measured_confounded=1', (kp->>'measured_confounded')::int = 1;
  INSERT INTO _t SELECT 'content_kpi: confident CP excludes confounded', (kp->>'incremental_cp_confident')::numeric = 0;
  kp := public.ai_quality_kpi(t, 60);
  INSERT INTO _t SELECT 'ai_kpi: actions_measured=2', (kp->>'actions_measured')::int = 2;
  INSERT INTO _t SELECT 'ai_kpi: actions_confounded≥1', (kp->>'actions_confounded')::int >= 1;
  sc := public.pilot_scorecard_v2(t, 14);
  INSERT INTO _t SELECT 'scorecard v2: has content/ai_quality/measured_cp/freshness', sc ?& ARRAY['content','ai_quality','measured_cp','freshness','evidence'];
  INSERT INTO _t SELECT 'scorecard v2: confounded_count ≥ 2', (sc->'measured_cp'->>'confounded_count')::int >= 2;

  -- 6. Quyền / audit
  PERFORM pg_temp.as_user(gen_random_uuid());
  PERFORM pg_temp.expect_error('measure: outsider denied', format('SELECT public.measure_subject(''action'', %L, 14)', act));
  INSERT INTO _t SELECT 'audit: measurements logged', EXISTS (SELECT 1 FROM public.audit_log WHERE entity_type = 'measurements' AND tenant_id = t);

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
