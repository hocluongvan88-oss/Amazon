-- ============================================================
-- Test 015 — chạy trong SQL Editor SAU 015. Tự ROLLBACK. Mong đợi toàn bộ PASS.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sku UUID; rv UUID; rid UUID; job UUID; fr JSONB; room JSONB; n INT;
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
  INSERT INTO public.tenants (slug, name) VALUES ('t014', 'Test 015') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, u_op, 'operator'), (t, u_qa, 'owner'), (t, u_view, 'viewer');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty)
  VALUES (t, 'B0TEST0015', 'T-015', 'Bình nước', 'US', 30, 10, 5, 15, 0) RETURNING id INTO sku;
  INSERT INTO public.sku_daily_snapshots (sku_id, tenant_id, asin, date, units, revenue, sessions, ad_spend, price, inventory_qty)
  VALUES (sku, t, 'B0TEST0015', CURRENT_DATE - 1, 2, 60, 100, 25, 30, 0);
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at) VALUES (t, 'B0TEST0015', 1, 'Leaks', 'Nắp bị rò', now()) RETURNING id INTO rv;

  -- 1. Tenant mới tự có nguồn csv_manual
  INSERT INTO _t SELECT 'source: csv_manual auto-created', (SELECT count(*) FROM public.data_sources WHERE tenant_id = t AND kind = 'csv_manual') = 1;
  INSERT INTO _t SELECT 'feeds: catalog seeded (9)', (SELECT count(*) FROM public.data_feeds) = 9;

  -- 2. Trước khi import: freshness = missing cho mọi feed (trừ orders có snapshot → vẫn missing vì chưa có run nhưng có data date)
  PERFORM pg_temp.as_user(u_op);
  fr := public.freshness_summary(t);
  INSERT INTO _t SELECT 'freshness: required_ok=false before import', COALESCE((fr->>'required_ok')::boolean, false) = false;
  INSERT INTO _t SELECT 'freshness: problems non-empty', jsonb_array_length(fr->'problems') > 0;
  INSERT INTO _t SELECT 'feed_is_fresh(orders_daily)=false', public.feed_is_fresh(t, 'orders_daily') = false;

  -- 3. import_jobs (CSV) → ingestion_run tự động, đúng feed, status theo rows
  INSERT INTO public.import_jobs (tenant_id, kind, filename, rows_total, rows_ok, rows_failed, created_by) VALUES (t, 'orders', 'orders.csv', 10, 10, 0, u_op) RETURNING id INTO job;
  INSERT INTO _t SELECT 'run: created from import_job (orders→orders_daily)', EXISTS (SELECT 1 FROM public.ingestion_runs WHERE import_job_id = job AND feed_key = 'orders_daily' AND status = 'succeeded');
  INSERT INTO _t SELECT 'run: external_ref = filename', (SELECT external_ref = 'orders.csv' FROM public.ingestion_runs WHERE import_job_id = job);
  INSERT INTO _t SELECT 'run: finished_at stamped', (SELECT finished_at IS NOT NULL FROM public.ingestion_runs WHERE import_job_id = job);
  INSERT INTO _t SELECT 'run: source_id = csv source', (SELECT s.kind = 'csv_manual' FROM public.ingestion_runs r JOIN public.data_sources s ON s.id = r.source_id WHERE r.import_job_id = job);
  INSERT INTO public.import_jobs (tenant_id, kind, filename, rows_total, rows_ok, rows_failed, created_by) VALUES (t, 'ads', 'ads.csv', 10, 7, 3, u_op) RETURNING id INTO job;
  INSERT INTO _t SELECT 'run: partial when rows_failed>0', (SELECT status = 'partial' FROM public.ingestion_runs WHERE import_job_id = job);
  INSERT INTO public.import_jobs (tenant_id, kind, filename, rows_total, rows_ok, rows_failed, created_by) VALUES (t, 'cogs', 'cogs.csv', 5, 0, 5, u_op) RETURNING id INTO job;
  INSERT INTO _t SELECT 'run: failed when rows_ok=0', (SELECT status = 'failed' FROM public.ingestion_runs WHERE import_job_id = job);
  INSERT INTO _t SELECT 'source: last_error set after failed run', (SELECT status = 'error' AND last_error IS NOT NULL FROM public.data_sources WHERE tenant_id = t AND kind = 'csv_manual');
  PERFORM pg_temp.expect_ok('import_jobs: kind reviews accepted', format('INSERT INTO public.import_jobs (tenant_id, kind, filename, rows_total, rows_ok, rows_failed) VALUES (%L,''reviews'',''r.csv'',1,1,0)', t));

  -- 4. Freshness sau import
  INSERT INTO _t SELECT 'feed_is_fresh(orders_daily)=true', public.feed_is_fresh(t, 'orders_daily') = true;
  INSERT INTO _t SELECT 'v_data_freshness: orders fresh', (SELECT status = 'fresh' AND last_data_date = CURRENT_DATE - 1 FROM public.v_data_freshness WHERE tenant_id = t AND feed_key = 'orders_daily');
  INSERT INTO _t SELECT 'v_data_freshness: ads settle lag → expected_through = today-4', (SELECT expected_through = CURRENT_DATE - 4 FROM public.v_data_freshness WHERE tenant_id = t AND feed_key = 'ads_daily');
  INSERT INTO _t SELECT 'v_data_freshness: cogs failed → still missing/stale', (SELECT status <> 'fresh' FROM public.v_data_freshness WHERE tenant_id = t AND feed_key = 'cogs');
  INSERT INTO _t SELECT 'v_data_freshness: catalog has data date from manual SKU (not missing)', (SELECT status <> 'missing' AND last_data_date = CURRENT_DATE AND last_success_at IS NULL FROM public.v_data_freshness WHERE tenant_id = t AND feed_key = 'catalog');
  INSERT INTO _t SELECT 'v_data_freshness: fees missing (no data, no run)', (SELECT status = 'missing' FROM public.v_data_freshness WHERE tenant_id = t AND feed_key = 'fees');
  -- run cũ hơn SLA → stale
  UPDATE public.ingestion_runs SET finished_at = now() - interval '5 days' WHERE tenant_id = t AND feed_key = 'orders_daily';
  INSERT INTO _t SELECT 'v_data_freshness: orders stale after 5d (SLA 36h)', (SELECT status = 'stale' FROM public.v_data_freshness WHERE tenant_id = t AND feed_key = 'orders_daily');
  INSERT INTO _t SELECT 'feed_is_fresh(orders_daily)=false when stale', public.feed_is_fresh(t, 'orders_daily') = false;

  -- 5. Control room v2 có freshness + signal high khi required chưa tươi
  room := public.asin_control_room_v2(sku);
  INSERT INTO _t SELECT 'room v2: has freshness', room ? 'freshness';
  INSERT INTO _t SELECT 'room v2: high signal about stale data', room->'signals' @> '[{"level":"high"}]';

  -- 6. Quản lý nguồn: cần policy.edit; không cho secret trong config; RLS tenant
  PERFORM pg_temp.expect_error('source: operator cannot upsert', format('SELECT public.upsert_data_source(%L, ''sp_api'', ''SP-API US'', ARRAY[''orders_daily''])', t));
  PERFORM pg_temp.as_user(u_qa);
  PERFORM pg_temp.expect_error('source: secret in config rejected', format('SELECT public.upsert_data_source(%L, ''sp_api'', ''SP-API US'', ARRAY[''orders_daily''], ''{"refresh_token":"x"}''::jsonb)', t));
  PERFORM pg_temp.expect_error('source: invalid feed rejected', format('SELECT public.upsert_data_source(%L, ''sp_api'', ''SP-API US'', ARRAY[''bogus''])', t));
  PERFORM pg_temp.expect_ok('source: owner upserts sp_api', format('SELECT public.upsert_data_source(%L, ''sp_api'', ''SP-API US'', ARRAY[''orders_daily'',''inventory''], ''{"marketplace_id":"ATVPDKIKX0DER"}''::jsonb, ''vault:spapi_us'')', t));
  INSERT INTO _t SELECT 'source: sp_api status not_connected', (SELECT status = 'not_connected' FROM public.data_sources WHERE tenant_id = t AND kind = 'sp_api');
  INSERT INTO _t SELECT 'v_data_sources: owner sees credential_ref', (SELECT credential_ref = 'vault:spapi_us' FROM public.v_data_sources WHERE tenant_id = t AND kind = 'sp_api');
  PERFORM pg_temp.as_user(u_view);
  INSERT INTO _t SELECT 'v_data_sources: viewer credential_ref hidden', (SELECT credential_ref IS NULL FROM public.v_data_sources WHERE tenant_id = t AND kind = 'sp_api');
  PERFORM pg_temp.as_user(gen_random_uuid());
  -- SQL Editor chạy với role postgres (bypass RLS) → chỉ kiểm policy + permission, không đếm bảng trực tiếp
  INSERT INTO _t SELECT 'rls: policies exist on ingestion_runs/data_sources', (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('ingestion_runs','data_sources')) >= 5;
  INSERT INTO _t SELECT 'rls: outsider has no data.import', public.has_permission(t, 'data.import') = false;
  INSERT INTO _t SELECT 'rls: outsider not in my_tenant_ids', NOT (t IN (SELECT public.my_tenant_ids()));
  INSERT INTO _t SELECT 'rls: outsider sees no freshness rows', (SELECT count(*) FROM public.v_data_freshness WHERE tenant_id = t) = 0;

  -- 7. audit
  INSERT INTO _t SELECT 'audit: data_sources logged', EXISTS (SELECT 1 FROM public.audit_log WHERE entity_type = 'data_sources' AND tenant_id = t);

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
