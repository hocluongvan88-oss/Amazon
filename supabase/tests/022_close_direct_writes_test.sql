-- ============================================================
-- TEST 022 — Feed cũ qua ingest_*, sku_save, đối soát orders ↔ traffic, không còn policy ghi
-- SQL Editor (postgres → RLS bypass, auth.uid() NULL). "0 FAIL" = pass; rollback toàn bộ.
-- ============================================================
DO $t$
DECLARE
  tn UUID; k1 UUID; k2 UUID; r JSONB; bid UUID; n INT; n2 INT; nn NUMERIC; txt TEXT; rec public.reconciliation_checks; k public.amazon_skus;
  fails TEXT[] := '{}'; passes INT := 0; d0 DATE := CURRENT_DATE - 5; d1 DATE := CURRENT_DATE - 4;
BEGIN
  INSERT INTO public.tenants (slug, name, marketplace) VALUES ('t022_' || substr(gen_random_uuid()::text, 1, 8), 'Test 022', 'US') RETURNING id INTO tn;

  -- ---------- 1. catalog qua ingest: tạo 2 SKU, dòng thiếu title lỗi ----------
  r := public.ingest_open(tn, 'catalog', 'catalog.csv', 'hash_cat_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('asin','B0TEST0001','sku','SKU-1','title','Yoga mat','current_price','25','reorder_point','40'),
    jsonb_build_object('asin','B0TEST0002','sku','SKU-2','title','Yoga block','current_price','30'),
    jsonb_build_object('asin','B0TEST0003','sku','SKU-3','current_price','30')));
  r := public.ingest_dry_run(bid);
  IF (r->>'rows_invalid')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'catalog dry-run invalid=1: ' || r::text); END IF;
  r := public.ingest_commit(bid);
  SELECT count(*) INTO n FROM public.amazon_skus WHERE tenant_id = tn;
  IF n = 2 AND (r->>'rows_inserted')::int = 2 AND r->>'status' = 'partial' THEN passes := passes + 1; ELSE fails := array_append(fails, 'catalog commit: ' || r::text); END IF;
  SELECT id INTO k1 FROM public.amazon_skus WHERE tenant_id = tn AND asin = 'B0TEST0001';
  SELECT id INTO k2 FROM public.amazon_skus WHERE tenant_id = tn AND asin = 'B0TEST0002';
  -- catalog lần 2: chỉ đổi giá, không xoá reorder_point
  r := public.ingest_open(tn, 'catalog', 'catalog2.csv', 'hash_cat_2'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(jsonb_build_object('asin','B0TEST0001','title','Yoga mat','current_price','27')));
  r := public.ingest_commit(bid);
  SELECT current_price, reorder_point INTO nn, n FROM public.amazon_skus WHERE id = k1;
  IF nn = 27 AND n = 40 AND (r->>'rows_updated')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, format('catalog update price=%s rop=%s', nn, n)); END IF;

  -- ---------- 2. cogs qua ingest → cogs_history + sync amazon_skus.cogs ----------
  r := public.ingest_open(tn, 'cogs', 'cogs.csv', 'hash_cogs_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('asin','B0TEST0001','cogs','8.5','effective_from',d0::text),
    jsonb_build_object('asin','B0TEST0009','cogs','1'),
    jsonb_build_object('asin','B0TEST0002','cogs','-3')));
  r := public.ingest_commit(bid);
  SELECT cogs, cogs_source INTO nn, txt FROM public.amazon_skus WHERE id = k1;
  IF nn = 8.5 AND txt = 'csv' AND (r->>'rows_error')::int = 1 AND (r->>'rows_invalid')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, format('cogs: %s cogs=%s src=%s', r::text, nn, txt)); END IF;

  -- ---------- 3. sales / inventory / fees ----------
  r := public.ingest_open(tn, 'sales', 's.csv', 'hash_s_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(jsonb_build_object('asin','B0TEST0001','sales_last_30d','60','revenue_last_30d','1500','sessions_last_30d','1200')));
  r := public.ingest_commit(bid);
  r := public.ingest_open(tn, 'inventory', 'i.csv', 'hash_i_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(jsonb_build_object('asin','B0TEST0001','inventory_qty','120','inventory_inbound','50')));
  r := public.ingest_commit(bid);
  r := public.ingest_open(tn, 'fees', 'f.csv', 'hash_f_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(jsonb_build_object('asin','B0TEST0001','fee_per_unit','4.25','referral_fee_pct','15')));
  r := public.ingest_commit(bid);
  SELECT sales_last_30d, inventory_qty INTO n, n2 FROM public.amazon_skus WHERE id = k1;
  SELECT fee_per_unit INTO nn FROM public.amazon_skus WHERE id = k1;
  SELECT fee_source INTO txt FROM public.amazon_skus WHERE id = k1;
  IF n = 60 AND n2 = 120 AND nn = 4.25 AND txt = 'csv' THEN passes := passes + 1; ELSE fails := array_append(fails, format('sales/inv/fees %s %s %s %s', n, n2, nn, txt)); END IF;
  SELECT inventory_qty INTO n FROM public.sku_daily_snapshots WHERE sku_id = k1 AND date = CURRENT_DATE;
  IF n = 120 THEN passes := passes + 1; ELSE fails := array_append(fails, 'inventory snapshot today'); END IF;
  SELECT count(*) INTO n FROM public.ingestion_runs WHERE tenant_id = tn AND feed_key IN ('catalog','cogs','sales_30d','inventory','fees') AND status IN ('succeeded','partial');
  IF n = 6 THEN passes := passes + 1; ELSE fails := array_append(fails, format('ingestion_runs for legacy feeds = %s (kỳ vọng 6)', n)); END IF;

  -- ---------- 4. reviews: rating ngoài 1–5 lỗi; trùng nội dung bị skip ----------
  r := public.ingest_open(tn, 'reviews', 'rv.csv', 'hash_rv_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('asin','B0TEST0001','rating','2','body','Mỏng hơn mô tả','verified_purchase','yes','reviewed_at',d0::text),
    jsonb_build_object('asin','B0TEST0001','rating','2','body','Mỏng hơn mô tả','verified_purchase','yes','reviewed_at',d0::text),
    jsonb_build_object('asin','B0TEST0001','rating','7','body','x')));
  r := public.ingest_commit(bid);
  SELECT count(*) INTO n FROM public.raw_reviews WHERE tenant_id = tn;
  IF n = 1 AND (r->>'rows_skipped')::int = 1 AND (r->>'rows_invalid')::int = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, 'reviews: ' || r::text || ' n=' || n); END IF;
  SELECT verified_purchase INTO txt FROM public.raw_reviews WHERE tenant_id = tn LIMIT 1;
  IF txt = 'true' THEN passes := passes + 1; ELSE fails := array_append(fails, 'verified bool'); END IF;

  -- ---------- 5. sku_save ----------
  k := public.sku_save(tn, '{"asin":"b0test0010","title":"Strap","current_price":12,"fee_per_unit":3}'::jsonb, NULL, 4.0, 'giá nhập');
  SELECT cogs, fee_per_unit INTO nn, n FROM public.amazon_skus WHERE id = k.id;
  SELECT count(*) INTO n2 FROM public.cogs_history WHERE sku_id = k.id;
  IF k.asin = 'B0TEST0010' AND nn = 4.0 AND n = 3 AND n2 = 1 THEN passes := passes + 1; ELSE fails := array_append(fails, format('sku_save insert cogs=%s fee=%s hist=%s', nn, n, n2)); END IF;
  k := public.sku_save(tn, '{"title":"Strap v2","status":"paused"}'::jsonb, k.id);
  IF k.title = 'Strap v2' AND k.status = 'paused' AND k.current_price = 12 THEN passes := passes + 1; ELSE fails := array_append(fails, 'sku_save update partial patch'); END IF;
  BEGIN k := public.sku_save(tn, '{"cogs": 1}'::jsonb, k.id); fails := array_append(fails, 'sku_save must reject cogs in patch');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  BEGIN k := public.sku_save(tn, '{"asin":"B0TEST0099"}'::jsonb, k.id); fails := array_append(fails, 'sku_save must reject asin change');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  BEGIN k := public.sku_save(tn, '{"asin":"B0TEST0001","title":"dup"}'::jsonb); fails := array_append(fails, 'sku_save must reject duplicate asin');
  EXCEPTION WHEN unique_violation THEN passes := passes + 1; WHEN others THEN passes := passes + 1; END;
  -- SKU của tenant khác không sửa được
  BEGIN k := public.sku_save(gen_random_uuid(), '{"title":"x"}'::jsonb, k1); fails := array_append(fails, 'sku_save cross-tenant');
  EXCEPTION WHEN others THEN passes := passes + 1; END;

  -- ---------- 6. Đối soát tự động orders ↔ traffic ----------
  BEGIN rec := public.run_reconciliation_auto(tn, d0, d1); fails := array_append(fails, 'auto recon must fail without data');
  EXCEPTION WHEN others THEN passes := passes + 1; END;
  r := public.ingest_open(tn, 'orders', 'o.csv', 'hash_o_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('order_id','1','order_date',d0::text,'asin','B0TEST0001','quantity','4','item_sales','100'),
    jsonb_build_object('order_id','2','order_date',d1::text,'asin','B0TEST0002','quantity','2','item_sales','60'),
    jsonb_build_object('order_id','3','order_date',d1::text,'asin','B0TEST0002','quantity','1','item_sales','30','status','Cancelled')));
  PERFORM public.ingest_commit(bid);
  r := public.ingest_open(tn, 'traffic', 't.csv', 'hash_t_1'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(
    jsonb_build_object('date',d0::text,'asin','B0TEST0001','sessions','100','units_ordered','4','ordered_product_sales','100'),
    jsonb_build_object('date',d1::text,'asin','B0TEST0002','sessions','50','units_ordered','2','ordered_product_sales','60')));
  PERFORM public.ingest_commit(bid);
  rec := public.run_reconciliation_auto(tn, d0, d1);
  IF rec.passed AND rec.kind = 'orders_vs_traffic' AND rec.sys_units = 6 AND rec.sc_units = 6 AND rec.sys_revenue = 160 THEN passes := passes + 1; ELSE fails := array_append(fails, format('auto recon pass: passed=%s u=%s/%s r=%s', rec.passed, rec.sys_units, rec.sc_units, rec.sys_revenue)); END IF;
  -- lệch: traffic thêm 3 đơn vị ở ASIN 2
  r := public.ingest_open(tn, 'traffic', 't2.csv', 'hash_t_2'); bid := (r->>'batch_id')::uuid;
  PERFORM public.ingest_add_rows(bid, jsonb_build_array(jsonb_build_object('date',d1::text,'asin','B0TEST0002','sessions','50','units_ordered','5','ordered_product_sales','150')));
  PERFORM public.ingest_commit(bid);
  rec := public.run_reconciliation_auto(tn, d0, d1);
  IF NOT rec.passed AND rec.detail->'asin_mismatches'->0->>'asin' = 'B0TEST0002' AND (rec.detail->'asin_mismatches'->0->>'diff')::int = -3 THEN passes := passes + 1; ELSE fails := array_append(fails, 'auto recon mismatch: ' || rec.detail::text); END IF;

  -- ---------- 7. Không còn policy ghi cho client ----------
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public'
    AND tablename IN ('amazon_skus','raw_reviews','cogs_history','import_jobs','sku_daily_snapshots','orders','returns','ad_daily','search_terms','promotions','traffic_daily','inventory_ledger','ingest_batches','ingest_rows')
    AND cmd <> 'SELECT';
  IF n = 0 THEN passes := passes + 1; ELSE fails := array_append(fails, format('%s write policies remain', n)); END IF;
  SELECT count(*) INTO n FROM public.ingest_feed_specs;
  IF n = 13 THEN passes := passes + 1; ELSE fails := array_append(fails, 'specs=13'); END IF;

  RAISE EXCEPTION 'KẾT QUẢ TEST 022: % PASS, % FAIL%', passes, cardinality(fails),
    CASE WHEN cardinality(fails) > 0 THEN E'\n - ' || array_to_string(fails, E'\n - ') ELSE ' — rollback sạch' END;
END $t$;
