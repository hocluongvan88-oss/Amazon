-- ============================================================
-- TEST 023 — Hàng đợi sync, backoff, secret không lộ, worker hooks, health không giả định
-- SQL Editor (postgres). "0 FAIL" = pass; rollback toàn bộ.
-- ============================================================
DO $t$
DECLARE
  tn UUID; src UUID; ads UUID; j public.sync_jobs; j2 public.sync_jobs; c JSONB; r JSONB; n INT; txt TEXT; ref TEXT;
  fails TEXT[] := '{}'; passes INT := 0;
BEGIN
  INSERT INTO public.tenants (slug, name, marketplace) VALUES ('t023_' || substr(gen_random_uuid()::text, 1, 8), 'Test 023', 'US') RETURNING id INTO tn;
  ref := 'sp_api:test:' || substr(gen_random_uuid()::text, 1, 8);
  INSERT INTO public.data_sources (tenant_id, kind, name, feeds, config, credential_ref, status) VALUES (tn, 'sp_api', 'SP test', ARRAY['orders_daily','sales_traffic_daily','inventory_ledger'], '{}'::jsonb, ref, 'connected') RETURNING id INTO src;
  INSERT INTO public.data_sources (tenant_id, kind, name, feeds, config, credential_ref, status) VALUES (tn, 'ads_api', 'Ads test', ARRAY['ads_daily'], '{}'::jsonb, NULL, 'not_connected') RETURNING id INTO ads;

  -- 1. feeds có connector_kind
  SELECT count(*) INTO n FROM public.data_feeds WHERE connector_kind IS NOT NULL;
  IF n = 6 THEN passes := passes + 1; ELSE fails := array_append(fails, format('connector feeds=%s', n)); END IF;

  -- 2. enqueue: hợp lệ / feed sai nguồn / không có credential / cửa sổ tương lai
  j := public.enqueue_sync(src, 'orders_daily', CURRENT_DATE - 3, CURRENT_DATE - 1, 'manual');
  IF j.status = 'queued' AND j.tenant_id = tn THEN passes := passes + 1; ELSE fails := array_append(fails, 'enqueue ok'); END IF;
  BEGIN j2 := public.enqueue_sync(src, 'ads_daily', CURRENT_DATE - 1, CURRENT_DATE - 1); fails := array_append(fails, 'ads feed on sp source must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  BEGIN j2 := public.enqueue_sync(ads, 'ads_daily', CURRENT_DATE - 1, CURRENT_DATE - 1); fails := array_append(fails, 'no credential must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  BEGIN j2 := public.enqueue_sync(src, 'orders_daily', CURRENT_DATE, CURRENT_DATE + 1); fails := array_append(fails, 'future window must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  -- idempotent: cùng cửa sổ → cùng job
  j2 := public.enqueue_sync(src, 'orders_daily', CURRENT_DATE - 3, CURRENT_DATE - 1, 'schedule');
  IF j2.id = j.id THEN passes := passes + 1; ELSE fails := array_append(fails, 'enqueue idempotent'); END IF;

  -- 3. backfill 7 ngày: sales_traffic = 7 job (1 ngày/job); orders = 1 job (7 ngày)
  r := public.backfill_sync(src, 'sales_traffic_daily', 7);
  SELECT count(*) INTO n FROM public.sync_jobs WHERE source_id = src AND feed_key = 'sales_traffic_daily';
  IF (r->>'jobs')::int = 7 AND n = 7 THEN passes := passes + 1; ELSE fails := array_append(fails, format('backfill traffic jobs=%s n=%s', r->>'jobs', n)); END IF;
  r := public.backfill_sync(src, 'orders_daily', 28);
  IF (r->>'jobs')::int = 4 THEN passes := passes + 1; ELSE fails := array_append(fails, 'backfill orders 28d → 4 jobs: ' || r::text); END IF;
  BEGIN r := public.backfill_sync(src, 'orders_daily', 10); fails := array_append(fails, 'backfill 10 must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- 4. claim: manual trước, trả đủ context, KHÔNG chứa secret
  c := public.claim_sync_job('tester', 600);
  IF (c->'job'->>'id')::uuid = j.id AND c->'job'->>'status' = 'running' AND c->'source'->>'credential_ref' = ref AND c->'tenant'->>'marketplace' = 'US'
     AND c->'feed'->>'amazon_report_type' = 'GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL'
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'claim context: ' || c::text); END IF;
  IF c::text NOT ILIKE '%refresh_token%' AND c::text NOT ILIKE '%client_secret%' THEN passes := passes + 1; ELSE fails := array_append(fails, 'claim leaks secret'); END IF;

  -- 5. progress + retryable fail → queued với backoff, attempt giữ
  PERFORM public.sync_job_progress(j.id, 'poll', 'REPORT123');
  j2 := public.finish_sync_job(j.id, 'failed', NULL, 'Amazon 429', 'rate_limit', true, 90);
  IF j2.status = 'queued' AND j2.attempt = 1 AND j2.external_ref = 'REPORT123' AND j2.next_attempt_at > now() + interval '60 seconds' THEN passes := passes + 1; ELSE fails := array_append(fails, format('retry: %s %s %s', j2.status, j2.attempt, j2.next_attempt_at)); END IF;
  -- chưa đến giờ → claim lấy job khác (traffic), không lấy lại job này
  c := public.claim_sync_job('tester', 600);
  IF (c->'job'->>'id')::uuid <> j.id THEN passes := passes + 1; ELSE fails := array_append(fails, 'claim must skip backoff job'); END IF;

  -- 6. lỗi auth không retry → failed + nguồn error + ingestion_runs failed
  j2 := public.finish_sync_job((c->'job'->>'id')::uuid, 'failed', NULL, 'LWA 400 invalid_grant', 'auth', false);
  SELECT status INTO txt FROM public.data_sources WHERE id = src;
  SELECT count(*) INTO n FROM public.ingestion_runs WHERE tenant_id = tn AND feed_key = 'sales_traffic_daily' AND status = 'failed';
  IF j2.status = 'failed' AND txt = 'error' AND n = 1 AND j2.run_id IS NOT NULL THEN passes := passes + 1; ELSE fails := array_append(fails, format('auth fail: %s src=%s runs=%s', j2.status, txt, n)); END IF;

  -- 7. max_attempts: retryable nhưng hết lượt → failed
  UPDATE public.sync_jobs SET attempt = 5 WHERE id = j.id;
  j2 := public.finish_sync_job(j.id, 'failed', NULL, 'still 429', 'rate_limit', true);
  IF j2.status = 'failed' THEN passes := passes + 1; ELSE fails := array_append(fails, 'max attempts'); END IF;

  -- 8. lease hết hạn được thu hồi
  UPDATE public.sync_jobs SET status = 'running', locked_at = now() - interval '2 hours', locked_by = 'dead' WHERE source_id = src AND feed_key = 'sales_traffic_daily' AND status = 'queued' AND id = (SELECT id FROM public.sync_jobs WHERE source_id = src AND feed_key = 'sales_traffic_daily' AND status = 'queued' LIMIT 1);
  c := public.claim_sync_job('tester2', 600);
  IF c IS NOT NULL AND c->'job'->>'locked_by' = 'tester2' THEN passes := passes + 1; ELSE fails := array_append(fails, 'lease reclaim'); END IF;
  -- success với run_id trong result
  j2 := public.finish_sync_job((c->'job'->>'id')::uuid, 'succeeded', jsonb_build_object('rows_inserted', 10), NULL, NULL, false);
  SELECT last_error INTO txt FROM public.data_sources WHERE id = src;
  IF j2.status = 'succeeded' AND j2.finished_at IS NOT NULL AND txt IS NULL THEN passes := passes + 1; ELSE fails := array_append(fails, 'success clears last_error'); END IF;

  -- 9. cancel chỉ job queued
  SELECT id INTO j.id FROM public.sync_jobs WHERE source_id = src AND status = 'queued' LIMIT 1;
  PERFORM public.cancel_sync_job(j.id);
  SELECT status INTO txt FROM public.sync_jobs WHERE id = j.id;
  IF txt = 'cancelled' THEN passes := passes + 1; ELSE fails := array_append(fails, 'cancel'); END IF;
  BEGIN PERFORM public.cancel_sync_job(j2.id); fails := array_append(fails, 'cancel succeeded job must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- 10. schedule_sync_jobs: nguồn error → bỏ qua; đặt lại connected → tạo job theo lookback
  UPDATE public.sync_jobs SET status = 'cancelled' WHERE source_id = src AND status IN ('queued','running');
  n := public.schedule_sync_jobs();
  SELECT count(*) INTO n FROM public.sync_jobs WHERE source_id = src AND status = 'queued';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'schedule must skip error source'); END IF;
  UPDATE public.data_sources SET status = 'connected' WHERE id = src;
  n := public.schedule_sync_jobs();
  SELECT count(*) INTO n FROM public.sync_jobs WHERE source_id = src AND status = 'queued' AND triggered_by = 'schedule';
  -- orders: 1 job (lookback 3), traffic: 3 job (1/ngày), inventory: 1 job = 5
  IF n = 5 THEN passes := passes + 1; ELSE fails := array_append(fails, format('schedule jobs=%s (kỳ vọng 5)', n)); END IF;

  -- 11. set_source_status từ chối secret trong config
  BEGIN PERFORM public.set_source_status(src, 'connected', NULL, '{"refresh_token":"x"}'::jsonb); fails := array_append(fails, 'config secret must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- 12. quyền: hàm worker/secret KHÔNG cấp cho authenticated/anon
  SELECT count(*) INTO n FROM information_schema.routine_privileges
   WHERE routine_schema = 'public' AND grantee IN ('authenticated','anon','PUBLIC')
     AND routine_name IN ('claim_sync_job','finish_sync_job','sync_job_progress','set_source_status','connector_secret_get','connector_secret_put','connector_secret_delete','schedule_sync_jobs','set_run_trigger','install_sync_cron');
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, format('%s worker/secret grants to authenticated/anon', n)); END IF;

  -- 13. ingest_open với source_id: worker (auth NULL) được; source khác tenant bị từ chối
  r := public.ingest_open(tn, 'orders', 'api', 'hash_api_1', NULL, src);
  IF (r->>'batch_id') IS NOT NULL THEN passes := passes + 1; ELSE fails := array_append(fails, 'ingest_open with source'); END IF;
  SELECT source_id::text INTO txt FROM public.ingest_batches WHERE id = (r->>'batch_id')::uuid;
  IF txt = src::text THEN passes := passes + 1; ELSE fails := array_append(fails, 'batch source_id'); END IF;
  BEGIN r := public.ingest_open(gen_random_uuid(), 'orders', 'api', 'hash_api_2', NULL, src); fails := array_append(fails, 'cross-tenant source must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- 14. health: không giả định; write_back false
  r := public.connector_health(tn);
  IF r->>'cron_status' IN ('ok','missing','unknown') AND (r->>'write_back_enabled')::boolean = false AND r ? 'worker_status' THEN passes := passes + 1; ELSE fails := array_append(fails, 'health: ' || r::text); END IF;

  -- 15. RLS bật + chỉ SELECT trên sync_jobs
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public' AND tablename = 'sync_jobs' AND cmd <> 'SELECT';
  IF n = 0 AND (SELECT rowsecurity FROM pg_tables WHERE schemaname = 'public' AND tablename = 'sync_jobs') THEN passes := passes + 1; ELSE fails := array_append(fails, 'sync_jobs RLS'); END IF;

  RAISE EXCEPTION 'KẾT QUẢ TEST 023: % PASS, % FAIL%', passes, cardinality(fails),
    CASE WHEN cardinality(fails) > 0 THEN E'\n - ' || array_to_string(fails, E'\n - ') ELSE ' — rollback sạch' END;
END $t$;
