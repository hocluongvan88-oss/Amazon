-- ============================================================
-- TEST 020 + 021 — Canonical data + server-side ingestion
-- Chạy trong SQL Editor (postgres → RLS bypass; auth.uid() NULL → bỏ qua check quyền).
-- Kết quả in ra bằng RAISE EXCEPTION cuối cùng (rollback toàn bộ). "0 FAIL" = pass.
-- ============================================================
DO $t$
DECLARE
  tn UUID; k1 UUID; k2 UUID; r JSONB; r2 JSONB; bid UUID; bid2 UUID; n INT; n2 INT; nn NUMERIC; txt TEXT;
  fails TEXT[] := '{}'; passes INT := 0; d0 DATE := CURRENT_DATE - 5; d1 DATE := CURRENT_DATE - 4;
BEGIN
  INSERT INTO public.tenants (slug, name, marketplace) VALUES ('t021_' || substr(gen_random_uuid()::text, 1, 8), 'Test 021', 'US') RETURNING id INTO tn;
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct)
    VALUES (tn, 'B0TEST0001', 'SKU-1', 'Test 1', 'US', 25, 8, 4, 15) RETURNING id INTO k1;
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct)
    VALUES (tn, 'B0TEST0002', 'SKU-2', 'Test 2', 'US', 30, 10, 5, 15) RETURNING id INTO k2;

  -- ---------- 1. parse helpers ----------
  IF public.ingest_parse_number('$1,234.50') = 1234.50 AND public.ingest_parse_number('1.234,50') = 1234.50 AND public.ingest_parse_number('abc') IS NULL
     AND public.ingest_parse_date('2026-09-01T10:15:00+00:00') = DATE '2026-09-01' AND public.ingest_parse_date('09/01/2026') = DATE '2026-09-01' AND public.ingest_parse_date('xx') IS NULL
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'parse helpers'); END IF;

  -- ---------- 2. normalize: lỗi từng dòng, không ném exception ----------
  r := public.ingest_normalize_row('orders', '{"order_id":"111-1","order_date":"bad","asin":"b0test0001","quantity":"2"}'::jsonb);
  IF (r->>'_ok')::boolean = false AND r->>'_err' LIKE '%order_date%' AND r->>'asin' = 'B0TEST0001'
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'normalize marks bad date, uppercases asin: ' || r::text); END IF;
  r := public.ingest_normalize_row('orders', '{"order_id":"111-1","asin":"B0TEST0001","quantity":"2"}'::jsonb);
  IF (r->>'_ok')::boolean = false AND r->>'_err' LIKE '%order_date: thiếu%' THEN passes := passes + 1; ELSE fails := array_append(fails, 'normalize required missing: ' || r::text); END IF;

  -- ---------- 3. ingest_open: feed không hỗ trợ bị từ chối ----------
  BEGIN
    r := public.ingest_open(tn, 'catalog', 'x.csv', 'hash_catalog_1');
    fails := array_append(fails, 'ingest_open should reject catalog');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- ---------- 4. orders: open → add (1 dòng lỗi) → dry-run → commit ----------
  r := public.ingest_open(tn, 'orders', 'orders.csv', 'hash_orders_1');
  bid := (r->>'batch_id')::uuid;
  IF (r->>'duplicate')::boolean = false AND r->>'feed_key' = 'orders_daily' THEN passes := passes + 1; ELSE fails := array_append(fails, 'ingest_open orders'); END IF;

  r := public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('order_id','111-0001','order_date',d0::text,'asin','B0TEST0001','sku','SKU-1','quantity','2','item_sales','49.98','status','Shipped'),
    jsonb_build_object('order_id','111-0002','order_date',d0::text,'asin','B0TEST0001','sku','SKU-1','quantity','1','item_sales','24.99','status','Cancelled'),
    jsonb_build_object('order_id','111-0003','order_date',d1::text,'asin','B0TEST0002','sku','SKU-2','quantity','3','item_sales','90','status','Shipped'),
    jsonb_build_object('order_id','111-0004','order_date',d1::text,'asin','B0TEST0009','sku','SKU-9','quantity','1','item_sales','10','status','Shipped'),
    jsonb_build_object('order_id','111-0005','order_date','31/31/2026','asin','B0TEST0001','sku','SKU-1','quantity','1','item_sales','10','status','Shipped')
  ));
  IF (r->>'valid')::int = 4 AND (r->>'invalid')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'add_rows counts: ' || r::text); END IF;

  r := public.ingest_dry_run(bid);
  IF (r->>'rows_invalid')::int = 1 AND (r->>'unknown_asin_count')::int = 1 AND r->'unknown_asins'->>0 = 'B0TEST0009'
     AND (r->>'date_min')::date = d0 AND (r->>'existing_days_in_range')::int = 0 AND (r->>'can_commit')::boolean AND jsonb_array_length(r->'errors') = 1
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'dry_run summary: ' || r::text); END IF;
  -- dry-run không ghi canonical
  SELECT count(*) INTO n FROM public.orders WHERE tenant_id = tn;
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'dry_run must not write orders'); END IF;

  r := public.ingest_commit(bid);
  IF r->>'status' = 'partial' AND (r->>'rows_inserted')::int = 4 AND (r->>'rows_invalid')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'commit orders: ' || r::text); END IF;
  SELECT count(*) INTO n FROM public.orders WHERE tenant_id = tn; 
  SELECT count(*) INTO n2 FROM public.orders WHERE tenant_id = tn AND is_cancelled;
  IF n = 4 AND n2 = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, format('orders rows=%s cancelled=%s', n, n2)); END IF;

  -- ingestion_runs được ghi với feed_key đúng, idempotency_key = file_hash
  SELECT count(*) INTO n FROM public.ingestion_runs WHERE tenant_id = tn AND feed_key = 'orders_daily' AND status = 'partial' AND idempotency_key = 'hash_orders_1' AND rows_failed = 1;
  IF n = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'ingestion_runs row'); END IF;

  -- derive: snapshot d0: SKU1 units=2 (bỏ cancelled), SKU2 units=0 (ngày có file nhưng không bán); d1: SKU2 = 3, SKU1 = 0
  SELECT units INTO n FROM public.sku_daily_snapshots WHERE sku_id = k1 AND date = d0;
  SELECT units INTO n2 FROM public.sku_daily_snapshots WHERE sku_id = k2 AND date = d0;
  IF n = 2 AND n2 = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, format('derive d0 sku1=%s sku2=%s', n, n2)); END IF;
  SELECT units INTO n FROM public.sku_daily_snapshots WHERE sku_id = k2 AND date = d1;
  IF n = 3 THEN passes := passes + 1; ELSE fails := array_append(fails, 'derive d1 sku2'); END IF;
  -- ngày không có file → KHÔNG có snapshot (missing ≠ zero)
  SELECT count(*) INTO n FROM public.sku_daily_snapshots WHERE tenant_id = tn AND date = CURRENT_DATE - 3;
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'missing day must not become zero'); END IF;

  -- ---------- 5. Idempotency ----------
  -- 5a: cùng file_hash → duplicate, không commit lại
  r := public.ingest_open(tn, 'orders', 'orders.csv', 'hash_orders_1');
  IF (r->>'duplicate')::boolean THEN passes := passes + 1; ELSE fails := array_append(fails, 'reopen same hash → duplicate'); END IF;
  BEGIN r := public.ingest_commit(bid); fails := array_append(fails, 'recommit must fail');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  -- 5b: file khác, nội dung trùng → skipped, không tăng dòng
  r := public.ingest_open(tn, 'orders', 'orders_again.csv', 'hash_orders_2');
  bid2 := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid2, jsonb_build_array(
    jsonb_build_object('order_id','111-0001','order_date',d0::text,'asin','B0TEST0001','sku','SKU-1','quantity','2','item_sales','49.98','status','Shipped'),
    jsonb_build_object('order_id','111-0003','order_date',d1::text,'asin','B0TEST0002','sku','SKU-2','quantity','5','item_sales','150','status','Shipped')));
  r := public.ingest_commit(bid2);
  SELECT count(*) INTO n FROM public.orders WHERE tenant_id = tn;
  IF (r->>'rows_skipped')::int = 1 AND (r->>'rows_updated')::int = 1 AND (r->>'rows_inserted')::int = 0 AND n = 4 AND r->>'status' = 'succeeded'
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'idempotent re-import: ' || r::text || ' rows=' || n); END IF;
  SELECT quantity INTO n FROM public.orders WHERE tenant_id = tn AND order_id = '111-0003';
  SELECT units INTO n2 FROM public.sku_daily_snapshots WHERE sku_id = k2 AND date = d1;
  IF n = 5 AND n2 = 5 THEN passes := passes + 1; ELSE fails := array_append(fails, format('restatement qty=%s snapshot=%s', n, n2)); END IF;

  -- ---------- 6. 1 dòng lỗi lúc commit không làm mất batch (quantity âm bị CHECK) ----------
  r := public.ingest_open(tn, 'returns', 'returns.csv', 'hash_ret_1');
  bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('return_date',d1::text,'order_id','111-0003','asin','B0TEST0002','quantity','1','reason','DEFECTIVE','refund_amount','30'),
    jsonb_build_object('return_date',d1::text,'order_id','111-0001','asin','B0TEST0001','quantity','1','reason','NOT_AS_DESCRIBED','refund_amount','24.99','customer_comment','Kích thước nhỏ hơn mô tả')));
  -- ép 1 dòng hợp lệ về validation nhưng vi phạm CHECK ở bảng đích
  UPDATE public.ingest_rows SET normalized = normalized || '{"quantity": -1}'::jsonb WHERE batch_id = bid AND row_no = 1;
  r := public.ingest_commit(bid);
  SELECT count(*) INTO n FROM public.returns WHERE tenant_id = tn;
  IF r->>'status' = 'partial' AND (r->>'rows_error')::int = 1 AND (r->>'rows_inserted')::int = 1 AND n = 1
  THEN passes := passes + 1; ELSE fails := array_append(fails, 'row error isolation: ' || r::text); END IF;
  SELECT outcome INTO txt FROM public.ingest_rows WHERE batch_id = bid AND row_no = 1;
  IF txt = 'error' THEN passes := passes + 1; ELSE fails := array_append(fails, 'row outcome error'); END IF;

  -- ---------- 7. ads: dimension + fact, derive ad_spend ----------
  r := public.ingest_open(tn, 'ads', 'ads.csv', 'hash_ads_1');
  bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('date',d0::text,'asin','B0TEST0001','campaign','SP-Auto','ad_group','AG1','impressions','4,210','clicks','58','spend','$31.20','sales','224.91','orders','9'),
    jsonb_build_object('date',d0::text,'campaign','SP-Auto','ad_group','AG1','keyword_text','yoga mat','match_type','broad','impressions','1000','clicks','20','spend','10','sales','50')));
  r := public.ingest_commit(bid);
  SELECT count(*) INTO n FROM public.ad_daily WHERE tenant_id = tn AND level = 'asin';
  SELECT count(*) INTO n2 FROM public.ad_keywords WHERE tenant_id = tn AND keyword_text = 'yoga mat';
  SELECT ad_spend INTO nn FROM public.sku_daily_snapshots WHERE sku_id = k1 AND date = d0;
  IF r->>'status' = 'succeeded' AND n = 1 AND n2 = 1 AND nn = 31.20 THEN passes := passes + 1; ELSE fails := array_append(fails, format('ads: %s asin=%s kw=%s spend=%s', r::text, n, n2, nn)); END IF;

  -- ---------- 8. traffic: sessions vào snapshot, KHÔNG ghi đè units từ orders ----------
  r := public.ingest_open(tn, 'traffic', 'traffic.csv', 'hash_tr_1');
  bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('date',d0::text,'asin','B0TEST0001','sessions','120','page_views','150','units_ordered','99','ordered_product_sales','999','buy_box_pct','98%','unit_session_pct','0.05')));
  r := public.ingest_commit(bid);
  SELECT sessions, units INTO n, n2 FROM public.sku_daily_snapshots WHERE sku_id = k1 AND date = d0;
  SELECT unit_session_pct INTO nn FROM public.traffic_daily WHERE tenant_id = tn AND asin = 'B0TEST0001';
  IF n = 120 AND n2 = 2 AND nn = 5 THEN passes := passes + 1; ELSE fails := array_append(fails, format('traffic sessions=%s units=%s usp=%s', n, n2, nn)); END IF;

  -- ---------- 9. inventory_ledger → snapshot + amazon_skus ----------
  r := public.ingest_open(tn, 'inventory_ledger', 'inv.csv', 'hash_inv_1');
  bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('date',d1::text,'asin','B0TEST0001','sku','SKU-1','fc','PHX7','available','40','inbound','10'),
    jsonb_build_object('date',d1::text,'asin','B0TEST0001','sku','SKU-1','fc','ONT8','available','25','inbound','0')));
  r := public.ingest_commit(bid);
  SELECT inventory_qty INTO n FROM public.amazon_skus WHERE id = k1;
  SELECT inventory_qty INTO n2 FROM public.sku_daily_snapshots WHERE sku_id = k1 AND date = d1;
  IF n = 65 AND n2 = 65 THEN passes := passes + 1; ELSE fails := array_append(fails, format('inventory ledger sku=%s snap=%s', n, n2)); END IF;

  -- ---------- 10. promotions: list ASIN, promo_type chuẩn hoá ----------
  r := public.ingest_open(tn, 'promotions', 'promo.csv', 'hash_pr_1');
  bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('promo_id','CPN-1','promo_type','Coupon','name','10% off','asins','B0TEST0001; b0test0002','start_at',d0::text,'end_at',(d0+7)::text,'discount_type','percent','discount_value','10'),
    jsonb_build_object('promo_id','LD-1','promo_type','Lightning Deal','asins','B0TEST0001','start_at',d1::text,'end_at',(d1-1)::text)));
  r := public.ingest_dry_run(bid);
  IF (r->>'rows_invalid')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'promo end<start invalid: ' || r::text); END IF;
  r := public.ingest_commit(bid);
  SELECT promo_type, cardinality(asins) INTO txt, n FROM public.promotions WHERE tenant_id = tn AND promo_id = 'CPN-1';
  IF txt = 'coupon' AND n = 2 THEN passes := passes + 1; ELSE fails := array_append(fails, format('promo type=%s asins=%s', txt, n)); END IF;

  -- ---------- 11. search_terms ----------
  r := public.ingest_open(tn, 'search_terms', 'st.csv', 'hash_st_1');
  bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('date',d0::text,'campaign','SP-Auto','ad_group','AG1','keyword_text','*','match_type','auto','search_term','Yoga Mat Thick','impressions','500','clicks','12','spend','6.1','orders','2','sales','49.98')));
  r := public.ingest_commit(bid);
  SELECT count(*) INTO n FROM public.search_terms WHERE tenant_id = tn AND search_term = 'yoga mat thick';
  IF n = 1 AND r->>'status' = 'succeeded' THEN passes := passes + 1; ELSE fails := array_append(fails, 'search_terms'); END IF;

  -- ---------- 12. Không có policy ghi trực tiếp trên canonical / snapshots ----------
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public'
    AND tablename IN ('orders','returns','ad_daily','ad_campaigns','ad_groups','ad_keywords','search_terms','promotions','traffic_daily','inventory_ledger','ingest_batches','ingest_rows','sku_daily_snapshots')
    AND cmd <> 'SELECT';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, format('%s write policies still exist on canonical/snapshots', n)); END IF;
  SELECT count(*) INTO n FROM pg_tables WHERE schemaname = 'public'
    AND tablename IN ('orders','returns','ad_daily','ad_campaigns','ad_groups','ad_keywords','search_terms','promotions','traffic_daily','inventory_ledger','ingest_batches','ingest_rows') AND NOT rowsecurity;
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'RLS disabled on some canonical tables'); END IF;

  -- ---------- 13. Freshness: feed mới có last_data_date; feed chưa nhập = missing ----------
  -- (view lọc theo my_tenant_ids → auth.uid NULL → dùng freshness_summary/feeds trực tiếp)
  SELECT count(*) INTO n FROM public.data_feeds WHERE feed_key IN ('returns','search_terms','promotions','inventory_ledger');
  SELECT count(*) INTO n2 FROM public.ingestion_runs WHERE tenant_id = tn AND status IN ('succeeded','partial');
  IF n = 4 AND n2 = 8 THEN passes := passes + 1; ELSE fails := array_append(fails, format('feeds=%s runs=%s', n, n2)); END IF;
  SELECT count(*) INTO n FROM public.ingestion_runs WHERE tenant_id = tn AND feed_key = 'cogs';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, 'cogs must stay missing'); END IF;

  -- ---------- 14. Dashboard cũ vẫn ra số (sku_metrics) ----------
  SELECT count(*) INTO n FROM public.sku_metrics(tn) m WHERE m.units_30d > 0;
  IF n = 2 THEN passes := passes + 1; ELSE fails := array_append(fails, format('sku_metrics units_30d>0 for %s skus (kỳ vọng 2)', n)); END IF;

  -- ---------- 15. Marketplace scoping ----------
  SELECT count(*) INTO n FROM public.orders WHERE tenant_id = tn AND marketplace = 'US';
  IF n = 4 THEN passes := passes + 1; ELSE fails := array_append(fails, 'marketplace tagged'); END IF;

  RAISE EXCEPTION 'KẾT QUẢ TEST 020/021: % PASS, % FAIL%', passes, cardinality(fails),
    CASE WHEN cardinality(fails) > 0 THEN E'\n - ' || array_to_string(fails, E'\n - ') ELSE ' — rollback sạch' END;
END $t$;
