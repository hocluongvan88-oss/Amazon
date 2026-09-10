-- ============================================================
-- 022 — PHASE 1c: Đóng đường ghi trực tiếp từ trình duyệt + đối soát orders ↔ traffic
-- Chạy SAU 021. Idempotent.
--   • 6 feed cũ (catalog, cogs, sales, inventory, fees, reviews) đi qua ingest_* như các feed khác.
--   • sku_save(): RPC duy nhất cho thêm/sửa/lưu trữ SKU + COGS mới (thay insert/update trực tiếp).
--   • Xoá policy ghi: amazon_skus, raw_reviews, cogs_history, import_jobs → chỉ SELECT từ client.
--   • reconciliation_checks.kind/detail + run_reconciliation_auto(): orders (canonical) ↔ traffic_daily theo ASIN.
-- ============================================================

-- 1. Spec cho 6 feed cũ
INSERT INTO public.ingest_feed_specs (import_kind, feed_key, schema_version, target_table, fields, natural_key, description) VALUES
 ('catalog','catalog',1,'amazon_skus', '[
   {"key":"asin","type":"text","required":true},{"key":"sku","type":"text"},{"key":"title","type":"text","required":true},
   {"key":"current_price","type":"number"},{"key":"list_price","type":"number"},{"key":"supplier","type":"text"},{"key":"lead_time_days","type":"int"},{"key":"reorder_point","type":"int"}]',
   ARRAY['asin'], 'Danh mục SKU'),
 ('cogs','cogs',1,'cogs_history', '[
   {"key":"asin","type":"text","required":true},{"key":"cogs","type":"number","required":true},{"key":"landed_cost","type":"number"},
   {"key":"effective_from","type":"date"},{"key":"note","type":"text"}]',
   ARRAY['asin','effective_from'], 'Giá vốn theo ngày hiệu lực (cần cogs.write)'),
 ('sales','sales_30d',1,'amazon_skus', '[
   {"key":"asin","type":"text","required":true},{"key":"sales_last_30d","type":"int","required":true},{"key":"revenue_last_30d","type":"number"},{"key":"sessions_last_30d","type":"int"}]',
   ARRAY['asin'], 'Doanh số 30 ngày (Business report tổng)'),
 ('inventory','inventory',1,'amazon_skus', '[
   {"key":"asin","type":"text","required":true},{"key":"sku","type":"text"},{"key":"inventory_qty","type":"int","required":true},{"key":"inventory_inbound","type":"int"}]',
   ARRAY['asin'], 'Tồn kho FBA hiện tại'),
 ('fees','fees',1,'amazon_skus', '[
   {"key":"asin","type":"text","required":true},{"key":"sku","type":"text"},{"key":"fee_per_unit","type":"number","required":true},{"key":"referral_fee_pct","type":"number"}]',
   ARRAY['asin'], 'Phí FBA & referral'),
 ('reviews','reviews',1,'raw_reviews', '[
   {"key":"asin","type":"text","required":true},{"key":"rating","type":"int","required":true},{"key":"title","type":"text"},{"key":"body","type":"text","required":true},
   {"key":"reviewed_at","type":"date"},{"key":"reviewer_id","type":"text"},{"key":"verified_purchase","type":"bool"}]',
   ARRAY['source_record_hash'], 'Review khách hàng (chỉ lắng nghe)')
ON CONFLICT (import_kind) DO UPDATE SET feed_key = EXCLUDED.feed_key, schema_version = EXCLUDED.schema_version, target_table = EXCLUDED.target_table,
  fields = EXCLUDED.fields, natural_key = EXCLUDED.natural_key, description = EXCLUDED.description;

-- raw_reviews: chống trùng theo hash nội dung
ALTER TABLE public.raw_reviews ADD COLUMN IF NOT EXISTS source_record_hash TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_raw_reviews_hash ON public.raw_reviews(tenant_id, source_record_hash) WHERE source_record_hash IS NOT NULL;

-- 2. Validate bổ sung cho feed cũ (rating 1–5, cogs ≥ 0)
CREATE OR REPLACE FUNCTION public.ingest_validate_extra(p_kind TEXT, res JSONB) RETURNS TEXT[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE errs TEXT[] := '{}';
BEGIN
  IF p_kind = 'reviews' AND ((res->>'rating')::int < 1 OR (res->>'rating')::int > 5) THEN errs := array_append(errs, 'rating: phải từ 1 đến 5'); END IF;
  IF p_kind = 'cogs' AND (res->>'cogs')::numeric < 0 THEN errs := array_append(errs, 'cogs: âm'); END IF;
  IF p_kind = 'fees' AND (res->>'fee_per_unit')::numeric < 0 THEN errs := array_append(errs, 'fee_per_unit: âm'); END IF;
  IF p_kind IN ('sales','inventory') AND (COALESCE((res->>'sales_last_30d')::int, 0) < 0 OR COALESCE((res->>'inventory_qty')::int, 0) < 0) THEN errs := array_append(errs, 'giá trị âm'); END IF;
  IF p_kind = 'catalog' AND (res->>'current_price')::numeric < 0 THEN errs := array_append(errs, 'current_price: âm'); END IF;
  RETURN errs;
END; $$;

-- Chuẩn hoá 1 dòng theo spec → {"_ok":bool,"_err":text,"_warn":text, ...fields}
CREATE OR REPLACE FUNCTION public.ingest_normalize_row(p_kind TEXT, p_raw JSONB)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE
  spec JSONB; f JSONB; k TEXT; ty TEXT; req BOOLEAN; rawv TEXT; outv JSONB; n NUMERIC; d DATE;
  res JSONB := '{}'::jsonb; errs TEXT[] := '{}'; warns TEXT[] := '{}';
BEGIN
  SELECT fields INTO spec FROM public.ingest_feed_specs WHERE import_kind = p_kind;
  IF spec IS NULL THEN RETURN jsonb_build_object('_ok', false, '_err', 'Loại feed không hỗ trợ: ' || p_kind); END IF;
  FOR f IN SELECT * FROM jsonb_array_elements(spec) LOOP
    k := f->>'key'; ty := f->>'type'; req := COALESCE((f->>'required')::boolean, false);
    rawv := NULLIF(trim(COALESCE(p_raw->>k, '')), '');
    outv := NULL;
    IF rawv IS NOT NULL THEN
      CASE ty
        WHEN 'int' THEN
          n := public.ingest_parse_number(rawv);
          IF n IS NULL THEN errs := array_append(errs, k || ': không phải số (' || left(rawv, 20) || ')');
          ELSE outv := to_jsonb(round(n)::bigint); END IF;
        WHEN 'number' THEN
          n := public.ingest_parse_number(rawv);
          IF n IS NULL THEN errs := array_append(errs, k || ': không phải số (' || left(rawv, 20) || ')'); ELSE outv := to_jsonb(n); END IF;
        WHEN 'percent' THEN
          n := public.ingest_parse_number(rawv);
          IF n IS NULL THEN errs := array_append(errs, k || ': không phải %');
          ELSE IF n < 1 AND rawv !~ '%' AND n > 0 THEN n := n * 100; END IF; outv := to_jsonb(round(n, 2)); END IF;
        WHEN 'date' THEN
          d := public.ingest_parse_date(rawv);
          IF d IS NULL THEN errs := array_append(errs, k || ': ngày không hợp lệ (' || left(rawv, 25) || ')');
          ELSIF d > CURRENT_DATE + 1 AND p_kind <> 'promotions' THEN errs := array_append(errs, k || ': ngày trong tương lai');
          ELSE outv := to_jsonb(d); END IF;
        WHEN 'bool' THEN outv := to_jsonb(lower(rawv) IN ('true','yes','y','1','x'));
        WHEN 'list' THEN outv := to_jsonb((SELECT array_agg(upper(trim(x))) FROM unnest(regexp_split_to_array(rawv, '[,;|\s]+')) x WHERE trim(x) <> ''));
        ELSE outv := to_jsonb(rawv);
      END CASE;
    END IF;
    IF req AND rawv IS NULL THEN errs := array_append(errs, k || ': thiếu'); END IF;
    IF outv IS NOT NULL THEN res := res || jsonb_build_object(k, outv); END IF;
  END LOOP;

  -- Kiểm tra nghiệp vụ theo feed
  IF res ? 'asin' THEN
    res := res || jsonb_build_object('asin', upper(res->>'asin'));
    IF (res->>'asin') !~ '^[A-Z0-9]{10}$' THEN errs := array_append(errs, 'asin: sai định dạng (10 ký tự chữ/số)'); END IF;
  END IF;
  IF (res->>'quantity')::numeric < 0 THEN errs := array_append(errs, 'quantity: âm'); END IF;
  IF (res->>'spend')::numeric < 0 THEN errs := array_append(errs, 'spend: âm'); END IF;
  IF p_kind = 'promotions' THEN
    res := res || jsonb_build_object('promo_type', CASE lower(regexp_replace(COALESCE(res->>'promo_type',''), '[^a-zA-Z]', '', 'g'))
      WHEN 'coupon' THEN 'coupon' WHEN 'lightningdeal' THEN 'lightning_deal' WHEN 'ld' THEN 'lightning_deal' WHEN 'bestdeal' THEN 'best_deal' WHEN 'deal' THEN 'best_deal'
      WHEN 'promotion' THEN 'promotion' WHEN 'promo' THEN 'promotion' WHEN 'primeexclusive' THEN 'prime_exclusive' WHEN 'ped' THEN 'prime_exclusive' ELSE 'other' END);
    IF jsonb_array_length(COALESCE(res->'asins', '[]'::jsonb)) = 0 THEN errs := array_append(errs, 'asins: thiếu'); END IF;
    IF (res->>'end_at')::date < (res->>'start_at')::date THEN errs := array_append(errs, 'end_at trước start_at'); END IF;
  END IF;
  IF p_kind = 'ads' THEN
    IF NOT (res ? 'asin') AND NOT (res ? 'campaign') THEN errs := array_append(errs, 'cần ít nhất asin hoặc campaign'); END IF;
    IF (res->>'clicks')::int > (res->>'impressions')::int THEN warns := array_append(warns, 'clicks > impressions'); END IF;
  END IF;
  IF p_kind = 'orders' AND lower(COALESCE(res->>'status','')) LIKE '%cancel%' THEN res := res || '{"is_cancelled":true}'::jsonb; END IF;
  errs := errs || public.ingest_validate_extra(p_kind, res);

  RETURN res || jsonb_build_object('_ok', cardinality(errs) = 0,
    '_err', NULLIF(array_to_string(errs, '; '), ''), '_warn', NULLIF(array_to_string(warns, '; '), ''));
END; $$;


-- 3. ingest_open v2 (cogs.write cho feed cogs)
CREATE OR REPLACE FUNCTION public.ingest_open(p_tenant UUID, p_kind TEXT, p_filename TEXT, p_file_hash TEXT, p_column_map JSONB DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sp RECORD; b RECORD; mk TEXT; sid UUID;
BEGIN
  PERFORM public.ingest_assert_permission(p_tenant);
  IF p_kind = 'cogs' AND auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'cogs.write') THEN RAISE EXCEPTION 'Nhập giá vốn cần quyền cogs.write'; END IF;
  SELECT * INTO sp FROM public.ingest_feed_specs WHERE import_kind = p_kind;
  IF sp IS NULL THEN RAISE EXCEPTION 'Loại feed không hỗ trợ ingest server-side: %', p_kind; END IF;
  IF p_file_hash IS NULL OR length(p_file_hash) < 8 THEN RAISE EXCEPTION 'Thiếu file_hash'; END IF;
  SELECT marketplace INTO mk FROM public.tenants WHERE id = p_tenant;
  IF mk IS NULL THEN RAISE EXCEPTION 'Tenant không tồn tại'; END IF;

  SELECT * INTO b FROM public.ingest_batches WHERE tenant_id = p_tenant AND import_kind = p_kind AND file_hash = p_file_hash AND status = 'committed';
  IF b.id IS NOT NULL THEN
    RETURN jsonb_build_object('batch_id', b.id, 'duplicate', true, 'status', b.status, 'committed_at', b.committed_at,
      'rows_inserted', b.rows_inserted, 'rows_updated', b.rows_updated, 'rows_skipped', b.rows_skipped);
  END IF;
  -- dọn batch mở dở của cùng file
  DELETE FROM public.ingest_batches WHERE tenant_id = p_tenant AND import_kind = p_kind AND file_hash = p_file_hash AND status IN ('open','validated','failed');

  sid := public.ensure_csv_source(p_tenant);
  INSERT INTO public.ingest_batches (tenant_id, marketplace, import_kind, feed_key, schema_version, source_id, filename, file_hash, column_map, created_by)
  VALUES (p_tenant, mk, p_kind, sp.feed_key, sp.schema_version, sid, p_filename, p_file_hash, p_column_map, auth.uid())
  RETURNING * INTO b;
  RETURN jsonb_build_object('batch_id', b.id, 'duplicate', false, 'status', b.status, 'schema_version', b.schema_version, 'feed_key', b.feed_key);
END; $$;


-- 4. ingest_commit v2 (thêm 6 feed cũ)
CREATE OR REPLACE FUNCTION public.ingest_commit(p_batch UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  b RECORD; r RECORD; n JSONB; ins BOOLEAN; touched BOOLEAN;
  n_ins INT := 0; n_upd INT := 0; n_skip INT := 0; n_err INT := 0; errs JSONB := '[]'::jsonb;
  d_min DATE; d_max DATE; run UUID; st TEXT; lvl TEXT; ck TEXT; gk TEXT; kk TEXT; derived JSONB; t0 TIMESTAMPTZ := clock_timestamp(); v_sku UUID;
BEGIN
  SELECT * INTO b FROM public.ingest_batches WHERE id = p_batch FOR UPDATE;
  IF b.id IS NULL THEN RAISE EXCEPTION 'Batch không tồn tại'; END IF;
  PERFORM public.ingest_assert_permission(b.tenant_id);
  IF b.import_kind = 'cogs' AND auth.uid() IS NOT NULL AND NOT public.has_permission(b.tenant_id, 'cogs.write') THEN RAISE EXCEPTION 'Nhập giá vốn cần quyền cogs.write'; END IF;
  IF b.status = 'committed' THEN RAISE EXCEPTION 'Batch đã commit lúc %', b.committed_at; END IF;
  IF b.rows_valid = 0 THEN RAISE EXCEPTION 'Không có dòng hợp lệ để ghi'; END IF;
  IF EXISTS (SELECT 1 FROM public.ingest_batches x WHERE x.tenant_id = b.tenant_id AND x.import_kind = b.import_kind AND x.file_hash = b.file_hash AND x.status = 'committed' AND x.id <> b.id) THEN
    RAISE EXCEPTION 'File này đã được ghi trước đó (trùng file_hash)';
  END IF;

  INSERT INTO public.ingestion_runs (tenant_id, source_id, feed_key, status, triggered_by, rows_total, external_ref, idempotency_key, started_at, created_by)
  VALUES (b.tenant_id, b.source_id, b.feed_key, 'running', 'manual', b.rows_total, b.filename, b.file_hash, now(), auth.uid()) RETURNING id INTO run;

  FOR r IN SELECT * FROM public.ingest_rows WHERE batch_id = p_batch AND valid ORDER BY row_no LOOP
    n := r.normalized; ins := NULL; touched := false;
    BEGIN
      CASE b.import_kind
      WHEN 'orders' THEN
        INSERT INTO public.orders AS t (tenant_id, marketplace, order_id, order_date, status, is_cancelled, fulfillment_channel, asin, sku, quantity, item_sales, currency, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, n->>'order_id', (n->>'order_date')::date, lower(n->>'status'), COALESCE((n->>'is_cancelled')::boolean, false), n->>'fulfillment_channel',
                n->>'asin', COALESCE(n->>'sku',''), (n->>'quantity')::int, (n->>'item_sales')::numeric, COALESCE(n->>'currency','USD'), b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, marketplace, order_id, asin, sku) DO UPDATE SET order_date = EXCLUDED.order_date, status = EXCLUDED.status, is_cancelled = EXCLUDED.is_cancelled,
          fulfillment_channel = EXCLUDED.fulfillment_channel, quantity = EXCLUDED.quantity, item_sales = EXCLUDED.item_sales, currency = EXCLUDED.currency, source_id = EXCLUDED.source_id,
          source_record_hash = EXCLUDED.source_record_hash, ingested_at = now()
        WHERE t.source_record_hash IS DISTINCT FROM EXCLUDED.source_record_hash
        RETURNING (xmax = 0) INTO ins;
        d_min := LEAST(d_min, (n->>'order_date')::date); d_max := GREATEST(d_max, (n->>'order_date')::date);

      WHEN 'returns' THEN
        INSERT INTO public.returns (tenant_id, marketplace, order_id, return_date, asin, sku, quantity, reason, customer_comment, refund_amount, disposition, status, return_ref, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, n->>'order_id', (n->>'return_date')::date, n->>'asin', COALESCE(n->>'sku',''), (n->>'quantity')::int, n->>'reason', n->>'customer_comment',
                (n->>'refund_amount')::numeric, n->>'disposition', n->>'status', n->>'return_ref', b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, source_record_hash) DO NOTHING
        RETURNING true INTO ins;
        d_min := LEAST(d_min, (n->>'return_date')::date); d_max := GREATEST(d_max, (n->>'return_date')::date);

      WHEN 'ads' THEN
        ck := COALESCE(n->>'campaign', ''); gk := COALESCE(n->>'ad_group', '');
        kk := CASE WHEN n ? 'keyword_text' THEN lower(n->>'keyword_text') || '|' || lower(COALESCE(n->>'match_type','')) ELSE '' END;
        lvl := CASE WHEN n ? 'asin' THEN 'asin' WHEN kk <> '' THEN 'keyword' WHEN gk <> '' THEN 'ad_group' ELSE 'campaign' END;
        IF ck <> '' THEN
          INSERT INTO public.ad_campaigns (tenant_id, marketplace, campaign_key, name) VALUES (b.tenant_id, b.marketplace, ck, n->>'campaign') ON CONFLICT DO NOTHING;
          IF gk <> '' THEN INSERT INTO public.ad_groups (tenant_id, marketplace, campaign_key, ad_group_key, name) VALUES (b.tenant_id, b.marketplace, ck, gk, n->>'ad_group') ON CONFLICT DO NOTHING; END IF;
          IF kk <> '' THEN INSERT INTO public.ad_keywords (tenant_id, marketplace, campaign_key, ad_group_key, keyword_key, keyword_text, match_type)
            VALUES (b.tenant_id, b.marketplace, ck, gk, kk, n->>'keyword_text', n->>'match_type') ON CONFLICT DO NOTHING; END IF;
        END IF;
        INSERT INTO public.ad_daily AS t (tenant_id, marketplace, date, level, campaign_key, ad_group_key, keyword_key, asin, impressions, clicks, spend, orders, sales, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, (n->>'date')::date, lvl, ck, gk, kk, COALESCE(n->>'asin',''), (n->>'impressions')::int, (n->>'clicks')::int, (n->>'spend')::numeric, (n->>'orders')::int, (n->>'sales')::numeric, b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, marketplace, date, level, campaign_key, ad_group_key, keyword_key, asin) DO UPDATE SET impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks,
          spend = EXCLUDED.spend, orders = EXCLUDED.orders, sales = EXCLUDED.sales, source_id = EXCLUDED.source_id, source_record_hash = EXCLUDED.source_record_hash, ingested_at = now()
        WHERE t.source_record_hash IS DISTINCT FROM EXCLUDED.source_record_hash
        RETURNING (xmax = 0) INTO ins;
        d_min := LEAST(d_min, (n->>'date')::date); d_max := GREATEST(d_max, (n->>'date')::date);

      WHEN 'search_terms' THEN
        ck := COALESCE(n->>'campaign', ''); gk := COALESCE(n->>'ad_group', '');
        kk := CASE WHEN n ? 'keyword_text' THEN lower(n->>'keyword_text') || '|' || lower(COALESCE(n->>'match_type','')) ELSE '' END;
        INSERT INTO public.search_terms AS t (tenant_id, marketplace, date, campaign_key, ad_group_key, keyword_key, keyword_text, match_type, search_term, asin, impressions, clicks, spend, orders, sales, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, (n->>'date')::date, ck, gk, kk, n->>'keyword_text', lower(COALESCE(n->>'match_type','')), lower(n->>'search_term'), COALESCE(n->>'asin',''),
                (n->>'impressions')::int, (n->>'clicks')::int, (n->>'spend')::numeric, (n->>'orders')::int, (n->>'sales')::numeric, b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, marketplace, date, campaign_key, ad_group_key, keyword_key, match_type, search_term, asin) DO UPDATE SET impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks,
          spend = EXCLUDED.spend, orders = EXCLUDED.orders, sales = EXCLUDED.sales, source_id = EXCLUDED.source_id, source_record_hash = EXCLUDED.source_record_hash, ingested_at = now()
        WHERE t.source_record_hash IS DISTINCT FROM EXCLUDED.source_record_hash
        RETURNING (xmax = 0) INTO ins;
        d_min := LEAST(d_min, (n->>'date')::date); d_max := GREATEST(d_max, (n->>'date')::date);

      WHEN 'promotions' THEN
        INSERT INTO public.promotions AS t (tenant_id, marketplace, promo_id, promo_type, name, asins, start_at, end_at, discount_type, discount_value, budget, status, margin_note, source, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, n->>'promo_id', n->>'promo_type', n->>'name', ARRAY(SELECT jsonb_array_elements_text(n->'asins')), (n->>'start_at')::date, (n->>'end_at')::date,
                n->>'discount_type', (n->>'discount_value')::numeric, (n->>'budget')::numeric, n->>'status', n->>'margin_note', 'csv', b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, marketplace, promo_id) DO UPDATE SET promo_type = EXCLUDED.promo_type, name = EXCLUDED.name, asins = EXCLUDED.asins, start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at,
          discount_type = EXCLUDED.discount_type, discount_value = EXCLUDED.discount_value, budget = EXCLUDED.budget, status = EXCLUDED.status, margin_note = EXCLUDED.margin_note,
          source_id = EXCLUDED.source_id, source_record_hash = EXCLUDED.source_record_hash, ingested_at = now()
        WHERE t.source_record_hash IS DISTINCT FROM EXCLUDED.source_record_hash
        RETURNING (xmax = 0) INTO ins;

      WHEN 'traffic' THEN
        INSERT INTO public.traffic_daily AS t (tenant_id, marketplace, date, asin, sessions, page_views, units_ordered, ordered_product_sales, buy_box_pct, unit_session_pct, impressions, clicks, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, (n->>'date')::date, n->>'asin', (n->>'sessions')::int, (n->>'page_views')::int, (n->>'units_ordered')::int, (n->>'ordered_product_sales')::numeric,
                (n->>'buy_box_pct')::numeric, (n->>'unit_session_pct')::numeric, (n->>'impressions')::int, (n->>'clicks')::int, b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, marketplace, date, asin) DO UPDATE SET sessions = EXCLUDED.sessions, page_views = EXCLUDED.page_views, units_ordered = EXCLUDED.units_ordered,
          ordered_product_sales = EXCLUDED.ordered_product_sales, buy_box_pct = EXCLUDED.buy_box_pct, unit_session_pct = EXCLUDED.unit_session_pct, impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks,
          source_id = EXCLUDED.source_id, source_record_hash = EXCLUDED.source_record_hash, ingested_at = now()
        WHERE t.source_record_hash IS DISTINCT FROM EXCLUDED.source_record_hash
        RETURNING (xmax = 0) INTO ins;
        d_min := LEAST(d_min, (n->>'date')::date); d_max := GREATEST(d_max, (n->>'date')::date);

      WHEN 'inventory_ledger' THEN
        INSERT INTO public.inventory_ledger AS t (tenant_id, marketplace, date, asin, sku, fc, available, reserved, inbound, unfulfillable, stranded, aged_90, aged_180, aged_270, aged_365, source_id, source_record_hash)
        VALUES (b.tenant_id, b.marketplace, (n->>'date')::date, n->>'asin', COALESCE(n->>'sku',''), COALESCE(n->>'fc',''), (n->>'available')::int, (n->>'reserved')::int, (n->>'inbound')::int,
                (n->>'unfulfillable')::int, (n->>'stranded')::int, (n->>'aged_90')::int, (n->>'aged_180')::int, (n->>'aged_270')::int, (n->>'aged_365')::int, b.source_id, r.row_hash)
        ON CONFLICT (tenant_id, marketplace, date, asin, sku, fc) DO UPDATE SET available = EXCLUDED.available, reserved = EXCLUDED.reserved, inbound = EXCLUDED.inbound, unfulfillable = EXCLUDED.unfulfillable,
          stranded = EXCLUDED.stranded, aged_90 = EXCLUDED.aged_90, aged_180 = EXCLUDED.aged_180, aged_270 = EXCLUDED.aged_270, aged_365 = EXCLUDED.aged_365,
          source_id = EXCLUDED.source_id, source_record_hash = EXCLUDED.source_record_hash, ingested_at = now()
        WHERE t.source_record_hash IS DISTINCT FROM EXCLUDED.source_record_hash
        RETURNING (xmax = 0) INTO ins;
        d_min := LEAST(d_min, (n->>'date')::date); d_max := GREATEST(d_max, (n->>'date')::date);
      WHEN 'catalog' THEN
        INSERT INTO public.amazon_skus AS t (tenant_id, marketplace, asin, sku, title, current_price, list_price, supplier, lead_time_days, reorder_point, last_ingested_at)
        VALUES (b.tenant_id, b.marketplace, n->>'asin', n->>'sku', n->>'title', COALESCE((n->>'current_price')::numeric, 0), (n->>'list_price')::numeric, n->>'supplier', (n->>'lead_time_days')::int, COALESCE((n->>'reorder_point')::int, 0), now())
        ON CONFLICT (tenant_id, asin, marketplace) DO UPDATE SET sku = COALESCE(EXCLUDED.sku, t.sku), title = COALESCE(EXCLUDED.title, t.title),
          current_price = CASE WHEN n ? 'current_price' THEN EXCLUDED.current_price ELSE t.current_price END, list_price = COALESCE(EXCLUDED.list_price, t.list_price),
          supplier = COALESCE(EXCLUDED.supplier, t.supplier), lead_time_days = COALESCE(EXCLUDED.lead_time_days, t.lead_time_days),
          reorder_point = CASE WHEN n ? 'reorder_point' THEN EXCLUDED.reorder_point ELSE t.reorder_point END, last_ingested_at = now()
        RETURNING (xmax = 0) INTO ins;

      WHEN 'cogs' THEN
        SELECT id INTO v_sku FROM public.amazon_skus WHERE tenant_id = b.tenant_id AND asin = n->>'asin' LIMIT 1;
        IF v_sku IS NULL THEN RAISE EXCEPTION 'ASIN % chưa có trong danh mục', n->>'asin'; END IF;
        INSERT INTO public.cogs_history AS t (tenant_id, sku_id, effective_from, cogs, landed_cost, source, note)
        VALUES (b.tenant_id, v_sku, COALESCE((n->>'effective_from')::date, CURRENT_DATE), (n->>'cogs')::numeric, (n->>'landed_cost')::numeric, 'csv', n->>'note')
        ON CONFLICT (sku_id, effective_from) DO UPDATE SET cogs = EXCLUDED.cogs, landed_cost = EXCLUDED.landed_cost, source = 'csv', note = EXCLUDED.note
        WHERE t.cogs IS DISTINCT FROM EXCLUDED.cogs OR t.landed_cost IS DISTINCT FROM EXCLUDED.landed_cost
        RETURNING (xmax = 0) INTO ins;

      WHEN 'sales' THEN
        UPDATE public.amazon_skus SET sales_last_30d = (n->>'sales_last_30d')::int, revenue_last_30d = COALESCE((n->>'revenue_last_30d')::numeric, revenue_last_30d),
          sessions_last_30d = COALESCE((n->>'sessions_last_30d')::int, sessions_last_30d), last_ingested_at = now()
        WHERE tenant_id = b.tenant_id AND asin = n->>'asin' RETURNING false INTO ins;
        IF ins IS NULL THEN RAISE EXCEPTION 'ASIN % chưa có trong danh mục', n->>'asin'; END IF;

      WHEN 'inventory' THEN
        UPDATE public.amazon_skus SET inventory_qty = (n->>'inventory_qty')::int, inventory_inbound = COALESCE((n->>'inventory_inbound')::int, inventory_inbound), last_ingested_at = now()
        WHERE tenant_id = b.tenant_id AND asin = n->>'asin' RETURNING id INTO v_sku;
        IF v_sku IS NULL THEN RAISE EXCEPTION 'ASIN % chưa có trong danh mục', n->>'asin'; END IF;
        INSERT INTO public.sku_daily_snapshots AS s (sku_id, date, tenant_id, asin, inventory_qty, inventory_inbound, sources)
        VALUES (v_sku, CURRENT_DATE, b.tenant_id, n->>'asin', (n->>'inventory_qty')::int, (n->>'inventory_inbound')::int, '{"inventory":"csv"}'::jsonb)
        ON CONFLICT (sku_id, date) DO UPDATE SET inventory_qty = EXCLUDED.inventory_qty, inventory_inbound = COALESCE(EXCLUDED.inventory_inbound, s.inventory_inbound), sources = s.sources || EXCLUDED.sources;
        ins := false;

      WHEN 'fees' THEN
        UPDATE public.amazon_skus SET fee_per_unit = (n->>'fee_per_unit')::numeric, referral_fee_pct = COALESCE((n->>'referral_fee_pct')::numeric, referral_fee_pct),
          fee_source = 'csv', fee_updated_at = now(), last_ingested_at = now()
        WHERE tenant_id = b.tenant_id AND asin = n->>'asin' RETURNING false INTO ins;
        IF ins IS NULL THEN RAISE EXCEPTION 'ASIN % chưa có trong danh mục', n->>'asin'; END IF;

      WHEN 'reviews' THEN
        IF NOT EXISTS (SELECT 1 FROM public.amazon_skus WHERE tenant_id = b.tenant_id AND asin = n->>'asin') THEN RAISE EXCEPTION 'ASIN % chưa có trong danh mục', n->>'asin'; END IF;
        INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at, reviewer_id, verified_purchase, source, source_record_hash)
        VALUES (b.tenant_id, n->>'asin', (n->>'rating')::int, n->>'title', n->>'body', (n->>'reviewed_at')::date, n->>'reviewer_id', COALESCE((n->>'verified_purchase')::boolean, false), 'csv', r.row_hash)
        ON CONFLICT (tenant_id, source_record_hash) WHERE source_record_hash IS NOT NULL DO NOTHING
        RETURNING true INTO ins;

      ELSE
        RAISE EXCEPTION 'Feed % chưa có mapping commit', b.import_kind;
      END CASE;

      IF ins IS NULL THEN n_skip := n_skip + 1; UPDATE public.ingest_rows SET outcome = 'skipped' WHERE batch_id = p_batch AND row_no = r.row_no;
      ELSIF ins THEN n_ins := n_ins + 1; UPDATE public.ingest_rows SET outcome = 'inserted' WHERE batch_id = p_batch AND row_no = r.row_no;
      ELSE n_upd := n_upd + 1; UPDATE public.ingest_rows SET outcome = 'updated' WHERE batch_id = p_batch AND row_no = r.row_no;
      END IF;
    EXCEPTION WHEN others THEN
      n_err := n_err + 1;
      IF jsonb_array_length(errs) < 200 THEN errs := errs || jsonb_build_object('row', r.row_no, 'error', SQLERRM); END IF;
      UPDATE public.ingest_rows SET outcome = 'error', error = SQLERRM WHERE batch_id = p_batch AND row_no = r.row_no;
    END;
  END LOOP;

  -- dòng không hợp lệ (validation) cũng là "failed" ở góc nhìn run
  SELECT errs || COALESCE(jsonb_agg(jsonb_build_object('row', row_no, 'error', error)), '[]'::jsonb) INTO errs
  FROM (SELECT row_no, error FROM public.ingest_rows WHERE batch_id = p_batch AND NOT valid ORDER BY row_no LIMIT 100) x;

  st := CASE WHEN n_ins + n_upd + n_skip = 0 THEN 'failed' WHEN n_err + b.rows_invalid > 0 THEN 'partial' ELSE 'succeeded' END;

  -- derive snapshots cho khoảng ngày vừa ghi (không chặn commit nếu derive lỗi)
  IF st <> 'failed' AND d_min IS NOT NULL AND b.import_kind IN ('orders','traffic','ads','inventory_ledger') THEN
    BEGIN
      derived := public.derive_snapshots(b.tenant_id, d_min, d_max,
        ARRAY[CASE b.import_kind WHEN 'inventory_ledger' THEN 'inventory' ELSE b.import_kind END]);
    EXCEPTION WHEN others THEN derived := jsonb_build_object('ok', false, 'error', SQLERRM); END;
  END IF;

  UPDATE public.ingestion_runs SET status = st, rows_ok = n_ins + n_upd + n_skip, rows_failed = n_err + b.rows_invalid,
    errors = CASE WHEN jsonb_array_length(errs) > 0 THEN errs END, window_start = d_min, window_end = d_max,
    finished_at = now(), duration_ms = (EXTRACT(EPOCH FROM clock_timestamp() - t0) * 1000)::int
  WHERE id = run;

  UPDATE public.ingest_batches SET status = CASE WHEN st = 'failed' THEN 'failed' ELSE 'committed' END,
    rows_inserted = n_ins, rows_updated = n_upd, rows_skipped = n_skip, rows_error = n_err, run_id = run, committed_at = now(),
    summary = COALESCE(summary, '{}'::jsonb) || jsonb_build_object('derived', derived)
  WHERE id = p_batch;

  RETURN jsonb_build_object('ok', st <> 'failed', 'status', st, 'run_id', run, 'batch_id', p_batch,
    'rows_inserted', n_ins, 'rows_updated', n_upd, 'rows_skipped', n_skip, 'rows_error', n_err, 'rows_invalid', b.rows_invalid,
    'window_start', d_min, 'window_end', d_max, 'derived', derived, 'errors', errs);
END; $$;


-- ------------------------------------------------------------
-- 5. sku_save — RPC duy nhất cho thêm/sửa/lưu trữ SKU từ UI
--    p_patch: các cột cho phép; p_new_cogs → cogs_history (cần cogs.write); đổi phí cần cogs.write
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sku_save(p_tenant UUID, p_patch JSONB, p_sku UUID DEFAULT NULL, p_new_cogs NUMERIC DEFAULT NULL, p_cogs_note TEXT DEFAULT NULL)
RETURNS public.amazon_skus LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE k public.amazon_skus; cur public.amazon_skus; v_asin TEXT; fee_changed BOOLEAN := false; mk TEXT;
  allowed TEXT[] := ARRAY['asin','sku','title','current_price','list_price','fee_per_unit','referral_fee_pct','inventory_qty','inventory_inbound','reorder_point','lead_time_days','supplier','status','sales_last_30d'];
  bad TEXT;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'sku.write') THEN RAISE EXCEPTION 'Không đủ quyền (sku.write)'; END IF;
  SELECT kk INTO bad FROM jsonb_object_keys(p_patch) AS kk WHERE kk <> ALL(allowed) LIMIT 1;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'Trường không được phép: %', bad; END IF;
  IF p_patch ? 'status' AND (p_patch->>'status') NOT IN ('active','paused','archived') THEN RAISE EXCEPTION 'status không hợp lệ'; END IF;
  SELECT marketplace INTO mk FROM public.tenants WHERE id = p_tenant;

  IF p_sku IS NULL THEN
    v_asin := upper(trim(COALESCE(p_patch->>'asin', '')));
    IF v_asin !~ '^[A-Z0-9]{10}$' THEN RAISE EXCEPTION 'ASIN không hợp lệ (10 ký tự chữ/số)'; END IF;
    IF COALESCE(trim(p_patch->>'title'), '') = '' THEN RAISE EXCEPTION 'Thiếu tên sản phẩm'; END IF;
    IF (p_patch ? 'fee_per_unit' AND COALESCE((p_patch->>'fee_per_unit')::numeric, 0) > 0) AND auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'cogs.write') THEN
      RAISE EXCEPTION 'Nhập phí FBA cần quyền cogs.write — để trống, Finance sẽ bổ sung';
    END IF;
    IF p_new_cogs IS NOT NULL AND p_new_cogs > 0 AND auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'cogs.write') THEN
      RAISE EXCEPTION 'Nhập giá vốn cần quyền cogs.write — để trống, Finance sẽ bổ sung';
    END IF;
    INSERT INTO public.amazon_skus (tenant_id, marketplace, asin, sku, title, current_price, list_price, fee_per_unit, referral_fee_pct, inventory_qty, inventory_inbound, reorder_point, lead_time_days, supplier, sales_last_30d, cogs, cogs_source, fee_source)
    VALUES (p_tenant, COALESCE(mk, 'US'), v_asin, NULLIF(trim(p_patch->>'sku'), ''), trim(p_patch->>'title'),
      COALESCE((p_patch->>'current_price')::numeric, 0), (p_patch->>'list_price')::numeric, COALESCE((p_patch->>'fee_per_unit')::numeric, 0), COALESCE((p_patch->>'referral_fee_pct')::numeric, 15),
      COALESCE((p_patch->>'inventory_qty')::int, 0), COALESCE((p_patch->>'inventory_inbound')::int, 0), COALESCE((p_patch->>'reorder_point')::int, 0), (p_patch->>'lead_time_days')::int,
      NULLIF(trim(p_patch->>'supplier'), ''), COALESCE((p_patch->>'sales_last_30d')::int, 0),
      COALESCE(p_new_cogs, 0), CASE WHEN p_new_cogs IS NOT NULL THEN 'manual' END, CASE WHEN COALESCE((p_patch->>'fee_per_unit')::numeric, 0) > 0 THEN 'manual' END)
    RETURNING * INTO k;
    IF p_new_cogs IS NOT NULL AND p_new_cogs > 0 THEN
      INSERT INTO public.cogs_history (tenant_id, sku_id, effective_from, cogs, source, note) VALUES (p_tenant, k.id, CURRENT_DATE, p_new_cogs, 'manual', p_cogs_note)
      ON CONFLICT (sku_id, effective_from) DO UPDATE SET cogs = EXCLUDED.cogs, note = EXCLUDED.note;
    END IF;
    RETURN k;
  END IF;

  SELECT * INTO cur FROM public.amazon_skus WHERE id = p_sku AND tenant_id = p_tenant FOR UPDATE;
  IF cur.id IS NULL THEN RAISE EXCEPTION 'SKU không tồn tại trong tenant'; END IF;
  IF p_patch ? 'asin' AND upper(p_patch->>'asin') <> cur.asin THEN RAISE EXCEPTION 'Không đổi ASIN của SKU đã có — tạo SKU mới'; END IF;
  fee_changed := (p_patch ? 'fee_per_unit' AND (p_patch->>'fee_per_unit')::numeric IS DISTINCT FROM cur.fee_per_unit)
              OR (p_patch ? 'referral_fee_pct' AND (p_patch->>'referral_fee_pct')::numeric IS DISTINCT FROM cur.referral_fee_pct);
  IF fee_changed AND auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'cogs.write') THEN RAISE EXCEPTION 'Đổi phí FBA/referral cần quyền cogs.write'; END IF;
  IF p_new_cogs IS NOT NULL AND p_new_cogs IS DISTINCT FROM cur.cogs AND auth.uid() IS NOT NULL AND NOT public.has_permission(p_tenant, 'cogs.write') THEN RAISE EXCEPTION 'Đổi giá vốn cần quyền cogs.write'; END IF;

  UPDATE public.amazon_skus SET
    sku = CASE WHEN p_patch ? 'sku' THEN NULLIF(trim(p_patch->>'sku'), '') ELSE sku END,
    title = CASE WHEN p_patch ? 'title' AND COALESCE(trim(p_patch->>'title'), '') <> '' THEN trim(p_patch->>'title') ELSE title END,
    current_price = CASE WHEN p_patch ? 'current_price' THEN COALESCE((p_patch->>'current_price')::numeric, current_price) ELSE current_price END,
    list_price = CASE WHEN p_patch ? 'list_price' THEN (p_patch->>'list_price')::numeric ELSE list_price END,
    fee_per_unit = CASE WHEN p_patch ? 'fee_per_unit' THEN COALESCE((p_patch->>'fee_per_unit')::numeric, fee_per_unit) ELSE fee_per_unit END,
    referral_fee_pct = CASE WHEN p_patch ? 'referral_fee_pct' THEN COALESCE((p_patch->>'referral_fee_pct')::numeric, referral_fee_pct) ELSE referral_fee_pct END,
    inventory_qty = CASE WHEN p_patch ? 'inventory_qty' THEN COALESCE((p_patch->>'inventory_qty')::int, inventory_qty) ELSE inventory_qty END,
    inventory_inbound = CASE WHEN p_patch ? 'inventory_inbound' THEN COALESCE((p_patch->>'inventory_inbound')::int, inventory_inbound) ELSE inventory_inbound END,
    reorder_point = CASE WHEN p_patch ? 'reorder_point' THEN COALESCE((p_patch->>'reorder_point')::int, reorder_point) ELSE reorder_point END,
    lead_time_days = CASE WHEN p_patch ? 'lead_time_days' THEN (p_patch->>'lead_time_days')::int ELSE lead_time_days END,
    supplier = CASE WHEN p_patch ? 'supplier' THEN NULLIF(trim(p_patch->>'supplier'), '') ELSE supplier END,
    status = CASE WHEN p_patch ? 'status' THEN p_patch->>'status' ELSE status END,
    sales_last_30d = CASE WHEN p_patch ? 'sales_last_30d' THEN COALESCE((p_patch->>'sales_last_30d')::int, sales_last_30d) ELSE sales_last_30d END,
    fee_source = CASE WHEN fee_changed THEN 'manual' ELSE fee_source END,
    fee_updated_at = CASE WHEN fee_changed THEN now() ELSE fee_updated_at END
  WHERE id = p_sku RETURNING * INTO k;

  IF p_new_cogs IS NOT NULL AND p_new_cogs IS DISTINCT FROM cur.cogs THEN
    INSERT INTO public.cogs_history (tenant_id, sku_id, effective_from, cogs, source, note) VALUES (p_tenant, p_sku, CURRENT_DATE, p_new_cogs, 'manual', p_cogs_note)
    ON CONFLICT (sku_id, effective_from) DO UPDATE SET cogs = EXCLUDED.cogs, note = EXCLUDED.note;
    SELECT * INTO k FROM public.amazon_skus WHERE id = p_sku;
  END IF;
  RETURN k;
END; $$;
GRANT EXECUTE ON FUNCTION public.sku_save(UUID, JSONB, UUID, NUMERIC, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 6. Đối soát tự động: orders (canonical) ↔ traffic_daily theo ASIN
-- ------------------------------------------------------------
ALTER TABLE public.reconciliation_checks ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'manual_sc';
ALTER TABLE public.reconciliation_checks DROP CONSTRAINT IF EXISTS reconciliation_checks_kind_check;
ALTER TABLE public.reconciliation_checks ADD CONSTRAINT reconciliation_checks_kind_check CHECK (kind IN ('manual_sc','orders_vs_traffic'));
ALTER TABLE public.reconciliation_checks ADD COLUMN IF NOT EXISTS detail JSONB;

CREATE OR REPLACE FUNCTION public.run_reconciliation_auto(t UUID, p_start DATE, p_end DATE)
RETURNS public.reconciliation_checks LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o_u INT; o_r NUMERIC; tr_u INT; tr_r NUMERIC; tol NUMERIC; rdiff NUMERIC; udiff NUMERIC; rec public.reconciliation_checks; det JSONB;
  days_orders INT; days_traffic INT; mism JSONB;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_permission(t, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền chạy đối soát (data.import)'; END IF;
  IF p_end < p_start THEN RAISE EXCEPTION 'Khoảng ngày không hợp lệ'; END IF;
  SELECT COALESCE(SUM(quantity),0), COALESCE(SUM(item_sales),0), COUNT(DISTINCT order_date) INTO o_u, o_r, days_orders
    FROM public.orders WHERE tenant_id = t AND NOT is_cancelled AND order_date BETWEEN p_start AND p_end;
  SELECT COALESCE(SUM(units_ordered),0), COALESCE(SUM(ordered_product_sales),0), COUNT(DISTINCT date) INTO tr_u, tr_r, days_traffic
    FROM public.traffic_daily WHERE tenant_id = t AND date BETWEEN p_start AND p_end;
  IF days_orders = 0 OR days_traffic = 0 THEN
    RAISE EXCEPTION 'Thiếu dữ liệu để đối soát: orders % ngày, traffic % ngày trong khoảng — nhập cả hai feed trước', days_orders, days_traffic;
  END IF;
  SELECT revenue_tolerance_pct INTO tol FROM public.policy_register WHERE tenant_id = t; tol := COALESCE(tol, 2);
  rdiff := CASE WHEN tr_r > 0 THEN ROUND(100 * (o_r - tr_r) / tr_r, 2) END;
  udiff := CASE WHEN tr_u > 0 THEN ROUND(100 * (o_u - tr_u)::numeric / tr_u, 2) END;
  -- top ASIN lệch
  SELECT COALESCE(jsonb_agg(jsonb_build_object('asin', asin, 'orders_units', ou, 'traffic_units', tu, 'diff', ou - tu) ORDER BY abs(ou - tu) DESC), '[]'::jsonb) INTO mism FROM (
    SELECT COALESCE(o.asin, tr.asin) asin, COALESCE(o.u,0) ou, COALESCE(tr.u,0) tu
    FROM (SELECT asin, SUM(quantity) u FROM public.orders WHERE tenant_id = t AND NOT is_cancelled AND order_date BETWEEN p_start AND p_end GROUP BY asin) o
    FULL JOIN (SELECT asin, SUM(units_ordered) u FROM public.traffic_daily WHERE tenant_id = t AND date BETWEEN p_start AND p_end GROUP BY asin) tr ON tr.asin = o.asin
    WHERE COALESCE(o.u,0) <> COALESCE(tr.u,0) LIMIT 20) x;
  det := jsonb_build_object('days_orders', days_orders, 'days_traffic', days_traffic, 'days_expected', (p_end - p_start + 1), 'asin_mismatches', mism);
  INSERT INTO public.reconciliation_checks
    (tenant_id, period_start, period_end, sc_revenue, sc_units, sys_revenue, sys_units, revenue_diff_pct, units_diff_pct, tolerance_pct, passed, note, created_by, kind, detail)
  VALUES (t, p_start, p_end, tr_r, tr_u, o_r, o_u, rdiff, udiff, tol,
          COALESCE(abs(rdiff) <= tol, FALSE) AND COALESCE(abs(udiff) <= tol, FALSE) AND days_orders = days_traffic,
          'Tự động: orders (All Orders) so với traffic_daily (Business report)', auth.uid(), 'orders_vs_traffic', det)
  RETURNING * INTO rec;
  RETURN rec;
END; $$;
GRANT EXECUTE ON FUNCTION public.run_reconciliation_auto(UUID, DATE, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 7. Đóng đường ghi trực tiếp từ client
-- ------------------------------------------------------------
DROP POLICY IF EXISTS skus_write   ON public.amazon_skus;
DROP POLICY IF EXISTS skus_update  ON public.amazon_skus;
DROP POLICY IF EXISTS skus_delete  ON public.amazon_skus;
DROP POLICY IF EXISTS reviews_write ON public.raw_reviews;
DROP POLICY IF EXISTS cogs_write   ON public.cogs_history;
DROP POLICY IF EXISTS import_insert ON public.import_jobs;

-- Self-check
DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('amazon_skus','raw_reviews','cogs_history','import_jobs','sku_daily_snapshots') AND cmd <> 'SELECT';
  RAISE NOTICE '022 self-check: specs=% (kỳ vọng 13), policy ghi còn lại trên bảng dữ liệu=% (kỳ vọng 0)', (SELECT count(*) FROM public.ingest_feed_specs), n;
END $$;
