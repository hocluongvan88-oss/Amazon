-- ============================================================
-- TEST 024 — Cockpit: missing ≠ zero, stale, baseline, hàng đợi P0–P3, mở task có evidence, tenant scoping
-- SQL Editor (postgres). "0 FAIL" = pass; rollback toàn bộ.
-- ============================================================
DO $t$
DECLARE
  tn UUID; tn2 UUID; sk UUID; c JSONB; a JSONB; x JSONB; n INT; tk public.tasks; tk2 public.tasks; d DATE := CURRENT_DATE - 1;
  fails TEXT[] := '{}'; passes INT := 0;
BEGIN
  INSERT INTO public.tenants (slug, name, marketplace) VALUES ('t024_' || substr(gen_random_uuid()::text, 1, 8), 'Test 024', 'US') RETURNING id INTO tn;
  INSERT INTO public.tenants (slug, name, marketplace) VALUES ('t024b_' || substr(gen_random_uuid()::text, 1, 8), 'Test 024 B', 'US') RETURNING id INTO tn2;

  -- ---------- 1. Tenant trống: mọi nhóm missing, KPI NULL (không phải 0), không có action nào ngoài data_quality ----------
  c := public.ops_cockpit(tn, d);
  SELECT count(*) INTO n FROM jsonb_each(c) e WHERE e.key IN ('orders','inventory','returns','keywords','traffic','conversion','promotions','reviews','advertising');
  IF n = 9 THEN passes := passes + 1; ELSE fails := array_append(fails, format('9 groups, got %s', n)); END IF;
  IF c->'orders'->'badge'->>'status' = 'missing' AND c->'advertising'->'badge'->>'status' = 'missing' THEN passes := passes + 1; ELSE fails := array_append(fails, 'empty tenant badge must be missing: ' || (c->'orders'->'badge')::text); END IF;
  IF (c->'orders'->'kpi'->'units_7d') = 'null'::jsonb AND (c->'traffic'->'kpi'->'sessions_7d') = 'null'::jsonb AND (c->'advertising'->'kpi'->'spend_7d') = 'null'::jsonb AND (c->'conversion'->'kpi'->'cvr_7d_pct') = 'null'::jsonb
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'missing must be NULL not 0: ' || (c->'orders'->'kpi')::text); END IF;
  IF (c->'orders'->>'has_data')::boolean = false THEN passes := passes + 1; ELSE fails := array_append(fails, 'has_data false'); END IF;
  a := public.cockpit_actions(tn, d);
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->>'group' <> 'data_quality';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, format('empty tenant non-DQ actions=%s', n)); END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->>'group' = 'data_quality' AND e->>'key' = 'dq_missing:orders' AND e->>'priority' = 'P1';
  IF n = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'DQ missing orders P1 expected'); END IF;

  -- ---------- 2. Dữ liệu: SKU + orders (60 ngày, tuần cuối giảm mạnh) + traffic + ads + returns + reviews + promo ----------
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty, last_ingested_at)
  VALUES (tn, 'B024TEST01', 'SKU-024', 'Test SKU', 'US', 30, 10, 5, 15, 0, now()) RETURNING id INTO sk;
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct, inventory_qty, last_ingested_at)
  VALUES (tn2, 'B024TEST02', 'SKU-024B', 'Other tenant', 'US', 30, 10, 5, 15, 100, now());
  -- baseline 30 ngày trước: 10 đơn/ngày; 30 ngày gần: 10/ngày trừ 7 ngày cuối = 3/ngày (giảm 70%)
  INSERT INTO public.orders (tenant_id, marketplace, order_id, order_date, status, is_cancelled, asin, sku, quantity, item_sales)
  SELECT tn, 'US', 'O' || g, d - g, 'shipped', false, 'B024TEST01', 'SKU-024', CASE WHEN g < 7 THEN 3 ELSE 10 END, CASE WHEN g < 7 THEN 90 ELSE 300 END FROM generate_series(0, 59) g;
  -- 1 đơn huỷ không tính
  INSERT INTO public.orders (tenant_id, marketplace, order_id, order_date, status, is_cancelled, asin, sku, quantity, item_sales) VALUES (tn, 'US', 'OCANCEL', d, 'cancelled', true, 'B024TEST01', 'SKU-024', 500, 0);
  -- tồn kho ledger: 0 khả dụng (đã biết, không phải thiếu dữ liệu)
  INSERT INTO public.inventory_ledger (tenant_id, marketplace, date, asin, sku, available, reserved, inbound, unfulfillable) VALUES (tn, 'US', d, 'B024TEST01', 'SKU-024', 0, 0, 0, 0);
  -- traffic: sessions 200/ngày baseline, 7 ngày cuối 100; units theo orders → CVR giảm
  INSERT INTO public.traffic_daily (tenant_id, marketplace, date, asin, sessions, page_views, units_ordered, ordered_product_sales, buy_box_pct)
  SELECT tn, 'US', d - g, 'B024TEST01', CASE WHEN g < 7 THEN 100 ELSE 200 END, 300, CASE WHEN g < 7 THEN 1 ELSE 10 END, 0, CASE WHEN g < 7 THEN 60 ELSE 98 END FROM generate_series(0, 59) g;
  -- ads: chi 10$/ngày, 0 sales trong 7 ngày cuối, SKU inventory_qty = 0 → spend_while_oos P0
  INSERT INTO public.ad_daily (tenant_id, marketplace, date, level, campaign_key, ad_group_key, keyword_key, asin, impressions, clicks, spend, orders, sales)
  SELECT tn, 'US', d - g, 'asin', 'C1', 'G1', '', 'B024TEST01', 1000, 50, 10, CASE WHEN g < 7 THEN 0 ELSE 2 END, CASE WHEN g < 7 THEN 0 ELSE 60 END FROM generate_series(0, 59) g;
  -- search terms: 1 harvest (3 đơn, broad), 1 negative (20 click 0 đơn)
  INSERT INTO public.search_terms (tenant_id, marketplace, date, campaign_key, ad_group_key, keyword_key, keyword_text, match_type, search_term, asin, impressions, clicks, spend, orders, sales)
  VALUES (tn, 'US', d - 2, 'C1', 'G1', 'K1', 'water bottle', 'broad', 'insulated water bottle 32oz', 'B024TEST01', 500, 20, 12, 3, 90),
         (tn, 'US', d - 2, 'C1', 'G1', 'K1', 'water bottle', 'broad', 'water bottle for dogs', 'B024TEST01', 900, 20, 15, 0, 0);
  -- returns: 30 ngày gần 5 trả trên 251 đơn vị đã bán → ~2% (dưới ngưỡng 8) → không action; review 1★ gần return → P1
  INSERT INTO public.returns (tenant_id, marketplace, order_id, return_date, asin, sku, quantity, reason, customer_comment, refund_amount)
  SELECT tn, 'US', 'O' || g, d - g, 'B024TEST01', 'SKU-024', 1, 'DEFECTIVE', 'leaks', 30 FROM generate_series(1, 5) g;
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, source, reviewed_at) VALUES (tn, 'B024TEST01', 1, 'Leaks', 'Lid leaks after a week', 'manual', (d - 2)::timestamptz);
  -- promo sắp chạy, giảm 60% → biên âm
  INSERT INTO public.promotions (tenant_id, marketplace, promo_id, promo_type, name, asins, start_at, end_at, discount_type, discount_value, status, source)
  VALUES (tn, 'US', 'PROMO-NEG', 'coupon', 'Big coupon', ARRAY['B024TEST01'], d + 3, d + 10, 'percent', 60, 'scheduled', 'manual');

  -- dựng snapshot từ canonical (như luồng ingest thật)
  PERFORM public.derive_snapshots(tn, d - 59, d);
  c := public.ops_cockpit(tn, d);
  -- 3. Orders: đơn huỷ loại trừ; baseline & change đúng
  IF (c->'orders'->'kpi'->>'units_1d')::int = 3 AND (c->'orders'->'kpi'->>'units_7d')::int = 21 AND (c->'orders'->'kpi'->>'units_baseline_30d')::int = 300
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'orders kpi: ' || (c->'orders'->'kpi')::text); END IF;
  IF (c->'orders'->'kpi'->>'change_7d_vs_baseline_pct')::numeric = -70 THEN passes := passes + 1; ELSE fails := array_append(fails, 'orders change -70 expected: ' || (c->'orders'->'kpi'->>'change_7d_vs_baseline_pct')); END IF;
  IF (c->'orders'->>'has_data')::boolean AND c->'orders'->'badge'->>'status' <> 'missing' THEN passes := passes + 1; ELSE fails := array_append(fails, 'orders badge after data: ' || (c->'orders'->'badge')::text); END IF;
  -- 4. Traffic/Conversion
  IF (c->'traffic'->'kpi'->>'sessions_7d')::int = 700 AND (c->'traffic'->'kpi'->>'change_7d_vs_baseline_pct')::numeric = -50 THEN passes := passes + 1; ELSE fails := array_append(fails, 'traffic kpi: ' || (c->'traffic'->'kpi')::text); END IF;
  IF (c->'conversion'->'kpi'->>'cvr_7d_pct')::numeric = 1 AND (c->'conversion'->'kpi'->>'cvr_baseline_pct')::numeric = 5 THEN passes := passes + 1; ELSE fails := array_append(fails, 'cvr kpi: ' || (c->'conversion'->'kpi')::text); END IF;
  IF c->'conversion'->'items'->0->>'diagnosis' = 'buy_box' THEN passes := passes + 1; ELSE fails := array_append(fails, 'diagnosis buy_box expected: ' || (c->'conversion'->'items'->0)::text); END IF;
  -- 5. Ads: ACOS 7d NULL (0 sales) không phải 0; flag spend_while_oos
  IF (c->'advertising'->'kpi'->>'spend_7d')::numeric = 70 AND (c->'advertising'->'kpi'->'acos_7d_pct') = 'null'::jsonb AND c->'advertising'->'items'->0->>'flag' = 'spend_while_oos'
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'ads: ' || (c->'advertising'->'kpi')::text || (c->'advertising'->'items'->0)::text); END IF;
  -- 6. Keywords: harvest + negative
  SELECT count(*) INTO n FROM jsonb_array_elements(c->'keywords'->'items') e WHERE e->>'kind' IN ('harvest','negative');
  IF n = 2 AND (c->'keywords'->'kpi'->>'wasted_spend_30d')::numeric = 15 THEN passes := passes + 1; ELSE fails := array_append(fails, 'keywords: ' || (c->'keywords')::text); END IF;
  -- 7. Returns: rate tính trên đơn vị bán 30 ngày (không tính huỷ)
  IF (c->'returns'->'kpi'->>'qty_30d')::int = 5 AND (c->'returns'->'kpi'->>'rate_30d_pct')::numeric BETWEEN 1.5 AND 2.5 THEN passes := passes + 1; ELSE fails := array_append(fails, 'returns: ' || (c->'returns'->'kpi')::text); END IF;
  -- 8. Reviews: có review thấp + has_nearby_return; Promotions: biên âm
  IF (c->'reviews'->'items'->0->>'has_nearby_return')::boolean AND (c->'reviews'->'kpi'->>'low_7d')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'reviews: ' || (c->'reviews')::text); END IF;
  IF (c->'promotions'->'kpi'->>'negative_margin')::int = 1 AND c->'promotions'->'items'->0->>'phase' = 'upcoming' THEN passes := passes + 1; ELSE fails := array_append(fails, 'promotions: ' || (c->'promotions')::text); END IF;
  -- 9. Inventory: 0 tồn + velocity → critical
  IF (c->'inventory'->'kpi'->>'critical')::int = 1 AND c->'inventory'->'badge'->>'feed' = 'inventory_ledger' THEN passes := passes + 1; ELSE fails := array_append(fails, 'inventory critical: ' || (c->'inventory'->'kpi')::text); END IF;

  -- ---------- 10. Action queue ----------
  a := public.cockpit_actions(tn, d);
  IF a->0->>'priority' = 'P0' THEN passes := passes + 1; ELSE fails := array_append(fails, 'first action must be P0: ' || (a->0)::text); END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->>'key' IN ('ads_oos:B024TEST01','inv_critical:B024TEST01','orders_drop','cvr_bb:B024TEST01','promo_margin:PROMO-NEG','traffic_drop:B024TEST01');
  IF n = 6 THEN passes := passes + 1; ELSE fails := array_append(fails, format('expected 6 core actions, got %s: %s', n, (SELECT string_agg(e->>'key', ',') FROM jsonb_array_elements(a) e))); END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->>'key' LIKE 'review_quality:%' AND e->>'priority' = 'P1';
  IF n = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'review_quality P1'); END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->>'key' LIKE 'ret_rate:%';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'return rate below threshold must not alert'); END IF;
  -- mọi mục có evidence/owner/deadline/link/title
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->'evidence' IS NULL OR e->>'owner_role' IS NULL OR e->>'deadline' IS NULL OR e->>'link' IS NULL OR e->>'title' IS NULL;
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, format('%s actions lack evidence/owner/deadline/link', n)); END IF;
  -- deadline P0 = SLA 4h (policy mặc định)
  SELECT e INTO x FROM jsonb_array_elements(a) e WHERE e->>'key' = 'ads_oos:B024TEST01';
  IF (x->>'deadline')::timestamptz BETWEEN now() + interval '3 hours 50 minutes' AND now() + interval '4 hours 10 minutes' THEN passes := passes + 1; ELSE fails := array_append(fails, 'P0 deadline 4h: ' || (x->>'deadline')); END IF;
  -- không có DQ missing cho orders nữa
  SELECT count(*) INTO n FROM jsonb_array_elements(a) e WHERE e->>'key' = 'dq_missing:orders';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'dq_missing orders should disappear'); END IF;

  -- ---------- 11. Tenant scoping: tenant B không thấy gì của A ----------
  c := public.ops_cockpit(tn2, d);
  IF (c->'orders'->'kpi'->'units_7d') = 'null'::jsonb AND jsonb_array_length(c->'advertising'->'items') = 0 AND jsonb_array_length(c->'inventory'->'items') = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'tenant B leakage: ' || (c->'orders'->'kpi')::text); END IF;

  -- ---------- 12. Mở task từ action: evidence, dedupe, SLA due ----------
  tk := public.cockpit_open_task(tn, x);
  IF tk.source_type = 'cockpit' AND tk.priority = 'P0' AND tk.type = 'ads_guardrail' AND tk.sku_id = sk AND tk.asin = 'B024TEST01' AND tk.evidence->'evidence'->>'spend_7d' IS NOT NULL AND tk.dedupe_key = 'ads_oos:B024TEST01'
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'open task: ' || to_jsonb(tk)::text); END IF;
  IF tk.due_at BETWEEN now() + interval '3 hours 50 minutes' AND now() + interval '4 hours 10 minutes' THEN passes := passes + 1; ELSE fails := array_append(fails, 'task due 4h'); END IF;
  tk2 := public.cockpit_open_task(tn, x);
  IF tk2.id = tk.id THEN passes := passes + 1; ELSE fails := array_append(fails, 'dedupe open task'); END IF;
  SELECT count(*) INTO n FROM public.tasks WHERE tenant_id = tn AND dedupe_key = 'ads_oos:B024TEST01';
  IF n = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, format('tasks dup=%s', n)); END IF;
  -- action queue báo task_id đã mở
  a := public.cockpit_actions(tn, d);
  SELECT e INTO x FROM jsonb_array_elements(a) e WHERE e->>'key' = 'ads_oos:B024TEST01';
  IF (x->>'task_id')::uuid = tk.id THEN passes := passes + 1; ELSE fails := array_append(fails, 'action task_id link'); END IF;
  -- action thiếu key → lỗi
  BEGIN tk2 := public.cockpit_open_task(tn, '{"title":"x"}'::jsonb); fails := array_append(fails, 'open task without key must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- ---------- 13. Stale: run cũ hơn SLA → badge stale ----------
  INSERT INTO public.ingestion_runs (tenant_id, feed_key, status, triggered_by, rows_total, rows_ok, started_at, finished_at)
  VALUES (tn, 'orders_daily', 'succeeded', 'manual', 1, 1, now() - interval '5 days', now() - interval '5 days');
  IF public.feed_badge(tn, 'orders_daily')->>'status' = 'stale' THEN passes := passes + 1; ELSE fails := array_append(fails, 'stale badge: ' || public.feed_badge(tn, 'orders_daily')::text); END IF;
  INSERT INTO public.ingestion_runs (tenant_id, feed_key, status, triggered_by, rows_total, rows_ok, started_at, finished_at)
  VALUES (tn, 'orders_daily', 'succeeded', 'manual', 1, 1, now() - interval '1 hour', now() - interval '1 hour');
  IF public.feed_badge(tn, 'orders_daily')->>'status' = 'fresh' THEN passes := passes + 1; ELSE fails := array_append(fails, 'fresh badge after new run'); END IF;

  -- ---------- 14. Không có hàm nào ghi lên Amazon / bảng business (chỉ tasks) ----------
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname IN ('ops_cockpit','cockpit_actions','feed_badge') AND p.provolatile <> 's';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'cockpit read fns must be STABLE'); END IF;

  RAISE EXCEPTION 'KẾT QUẢ TEST 024: % PASS, % FAIL%', passes, cardinality(fails),
    CASE WHEN cardinality(fails) > 0 THEN E'\n - ' || array_to_string(fails, E'\n - ') ELSE ' — rollback sạch' END;
END $t$;
