-- ============================================================
-- Test 014 — chạy trong SQL Editor SAU 014. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sku UUID; rv UUID; tk UUID; tid UUID; sug JSONB; room JSONB; n INT;
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
  INSERT INTO public.tenants (slug, name) VALUES ('t014', 'Test 014') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'content_qa'), (t, u_view, 'viewer');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
  VALUES (t, 'B0TEST0014', 'T-014', 'Bình nước', 'US', 30, 10, 5, 15, 0) RETURNING id INTO sku;
  INSERT INTO public.sku_daily_snapshots (sku_id, tenant_id, asin, date, units, revenue, sessions, ad_spend, price, inventory_qty)
  VALUES (sku, t, 'B0TEST0014', CURRENT_DATE - 1, 2, 60, 100, 25, 30, 0);
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at) VALUES (t, 'B0TEST0014', 1, 'Leaks', 'Nắp bị rò', now()) RETURNING id INTO rv;

  -- 1. Ticket defect → gợi ý gồm qa_product + content + ads_guardrail (có ad spend) + support + inventory (hết hàng)
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO public.voc_tickets (tenant_id, asin, sku_id, type, priority, title, review_ids) VALUES (t, 'B0TEST0014', sku, 'defect', 'P1', 'Nắp rò rỉ', ARRAY[rv]) RETURNING id INTO tk;
  sug := public.suggest_tasks_for_ticket(tk);
  INSERT INTO _t SELECT 'suggest: has qa_product', sug @> '[{"type":"qa_product"}]';
  INSERT INTO _t SELECT 'suggest: has content', sug @> '[{"type":"content"}]';
  INSERT INTO _t SELECT 'suggest: has ads_guardrail (ad spend > 0)', sug @> '[{"type":"ads_guardrail"}]';
  INSERT INTO _t SELECT 'suggest: has support', sug @> '[{"type":"support"}]';
  INSERT INTO _t SELECT 'suggest: has inventory_investigation (OOS)', sug @> '[{"type":"inventory_investigation"}]';

  -- 2. viewer không tạo được task; operator tạo được; idempotent; ticket → investigating
  PERFORM pg_temp.as_user(u_view);
  PERFORM pg_temp.expect_error('tasks: viewer cannot create', format('SELECT count(*) FROM public.create_tasks_from_ticket(%L, %L::jsonb)', tk, sug::text));
  PERFORM pg_temp.as_user(u_op);
  SELECT count(*) INTO n FROM public.create_tasks_from_ticket(tk, sug);
  INSERT INTO _t SELECT 'tasks: created 5', n = 5;
  SELECT count(*) INTO n FROM public.create_tasks_from_ticket(tk, sug);
  INSERT INTO _t SELECT 'tasks: idempotent (still 5 rows)', (SELECT count(*) FROM public.tasks WHERE source_id = tk) = 5;
  INSERT INTO _t SELECT 'tasks: ticket → investigating', (SELECT status = 'investigating' FROM public.voc_tickets WHERE id = tk);
  INSERT INTO _t SELECT 'tasks: evidence has review_ids', (SELECT (evidence->'review_ids') @> to_jsonb(ARRAY[rv]) FROM public.tasks WHERE source_id = tk LIMIT 1);
  INSERT INTO _t SELECT 'tasks: due_at set by priority', (SELECT bool_and(due_at IS NOT NULL) FROM public.tasks WHERE source_id = tk);

  -- 3. Đóng task cần outcome; permission theo loại
  SELECT id INTO tid FROM public.tasks WHERE source_id = tk AND type = 'content' LIMIT 1;
  PERFORM pg_temp.expect_error('tasks: done without outcome fails', format('UPDATE public.tasks SET status=''done'' WHERE id=%L', tid));
  PERFORM pg_temp.expect_ok('tasks: done with outcome', format('UPDATE public.tasks SET status=''done'', outcome=''Đã thêm bullet hướng dẫn khoá nắp'' WHERE id=%L', tid));
  INSERT INTO _t SELECT 'tasks: done_by/done_at stamped', (SELECT done_by = u_op AND done_at IS NOT NULL FROM public.tasks WHERE id = tid);
  SELECT id INTO tid FROM public.tasks WHERE source_id = tk AND type = 'qa_product' LIMIT 1;
  PERFORM pg_temp.as_user(u_view);
  PERFORM pg_temp.expect_error('tasks: viewer cannot progress', format('UPDATE public.tasks SET status=''in_progress'' WHERE id=%L', tid));

  -- 4. content_opportunity từ listing audit (SKU không có fact/A+/bullets → điểm ≥ 50)
  PERFORM pg_temp.as_user(u_qa);
  SELECT public.create_content_opportunity_tasks(t, 50) INTO n;
  INSERT INTO _t SELECT 'opportunity: task created', n >= 1;
  SELECT public.create_content_opportunity_tasks(t, 50) INTO n;
  INSERT INTO _t SELECT 'opportunity: idempotent while open', n = 0;

  -- 5. Control room
  PERFORM pg_temp.as_user(u_op);
  room := public.asin_control_room(sku);
  INSERT INTO _t SELECT 'room: has all sections', room ?& ARRAY['sku','revenue','margin','ads','inventory','risk','content','voc','queue','actions','signals'];
  INSERT INTO _t SELECT 'room: voc counts', (room->'voc'->>'neg_reviews_90d')::int = 1 AND (room->'voc'->>'open_tickets')::int = 1;
  INSERT INTO _t SELECT 'room: tasks_open counted', (room->'queue'->>'tasks_open')::int >= 4;
  INSERT INTO _t SELECT 'room: signals non-empty', jsonb_array_length(room->'signals') > 0;
  PERFORM pg_temp.as_user(gen_random_uuid());
  PERFORM pg_temp.expect_error('room: outsider denied', format('SELECT public.asin_control_room(%L)', sku));

  -- 6. audit
  INSERT INTO _t SELECT 'audit: tasks logged', EXISTS (SELECT 1 FROM public.audit_log WHERE entity_type = 'tasks' AND tenant_id = t);

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
