-- ============================================================
-- 021 — PHASE 1b: Server-side ingestion (staging → dry-run → commit)
-- Chạy SAU 020. Idempotent.
--   • ingest_feed_specs : hợp đồng dữ liệu (schema_version, fields, natural key) — CSV và API dùng CHUNG.
--   • ingest_batches / ingest_rows : staging. Trình duyệt chỉ gửi dòng thô (chuỗi) → server parse + validate.
--   • ingest_open → ingest_add_rows → ingest_dry_run → ingest_commit.
--   • Idempotent: trùng file_hash → trả batch cũ; trùng source_record_hash → skip; 1 dòng lỗi không làm mất batch.
--   • Sau commit: derive_snapshots (020) để dashboard cũ vẫn có số.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Hợp đồng feed
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ingest_feed_specs (
  import_kind    TEXT PRIMARY KEY,
  feed_key       TEXT NOT NULL REFERENCES public.data_feeds(feed_key),
  schema_version INT  NOT NULL DEFAULT 1,
  target_table   TEXT NOT NULL,
  fields         JSONB NOT NULL,      -- [{key,type:text|int|number|date|percent|bool|list,required}]
  natural_key    TEXT[] NOT NULL,
  description    TEXT
);
INSERT INTO public.ingest_feed_specs (import_kind, feed_key, schema_version, target_table, fields, natural_key, description) VALUES
 ('orders','orders_daily',1,'orders', '[
   {"key":"order_id","type":"text","required":true},{"key":"order_date","type":"date","required":true},
   {"key":"asin","type":"text","required":true},{"key":"sku","type":"text"},{"key":"quantity","type":"int","required":true},
   {"key":"item_sales","type":"number"},{"key":"status","type":"text"},{"key":"fulfillment_channel","type":"text"},{"key":"currency","type":"text"}]',
   ARRAY['order_id','asin','sku'], 'All Orders report – 1 dòng = 1 order line'),
 ('returns','returns',1,'returns', '[
   {"key":"return_date","type":"date","required":true},{"key":"order_id","type":"text"},{"key":"asin","type":"text","required":true},
   {"key":"sku","type":"text"},{"key":"quantity","type":"int","required":true},{"key":"reason","type":"text"},{"key":"customer_comment","type":"text"},
   {"key":"refund_amount","type":"number"},{"key":"disposition","type":"text"},{"key":"status","type":"text"},{"key":"return_ref","type":"text"}]',
   ARRAY['source_record_hash'], 'FBA customer returns'),
 ('ads','ads_daily',1,'ad_daily', '[
   {"key":"date","type":"date","required":true},{"key":"asin","type":"text"},{"key":"campaign","type":"text"},{"key":"ad_group","type":"text"},
   {"key":"keyword_text","type":"text"},{"key":"match_type","type":"text"},{"key":"impressions","type":"int"},{"key":"clicks","type":"int"},
   {"key":"spend","type":"number","required":true},{"key":"orders","type":"int"},{"key":"sales","type":"number"}]',
   ARRAY['date','level','campaign_key','ad_group_key','keyword_key','asin'], 'Sponsored Products daily (advertised product / keyword / campaign)'),
 ('search_terms','search_terms',1,'search_terms', '[
   {"key":"date","type":"date","required":true},{"key":"campaign","type":"text"},{"key":"ad_group","type":"text"},{"key":"keyword_text","type":"text"},
   {"key":"match_type","type":"text"},{"key":"search_term","type":"text","required":true},{"key":"asin","type":"text"},
   {"key":"impressions","type":"int"},{"key":"clicks","type":"int"},{"key":"spend","type":"number"},{"key":"orders","type":"int"},{"key":"sales","type":"number"}]',
   ARRAY['date','campaign_key','ad_group_key','keyword_key','match_type','search_term','asin'], 'SP search term report'),
 ('promotions','promotions',1,'promotions', '[
   {"key":"promo_id","type":"text","required":true},{"key":"promo_type","type":"text","required":true},{"key":"name","type":"text"},
   {"key":"asins","type":"list","required":true},{"key":"start_at","type":"date","required":true},{"key":"end_at","type":"date"},
   {"key":"discount_type","type":"text"},{"key":"discount_value","type":"number"},{"key":"budget","type":"number"},{"key":"status","type":"text"},{"key":"margin_note","type":"text"}]',
   ARRAY['promo_id'], 'Lịch khuyến mãi (coupon/deal/promotion)'),
 ('traffic','sales_traffic_daily',1,'traffic_daily', '[
   {"key":"date","type":"date","required":true},{"key":"asin","type":"text","required":true},{"key":"sessions","type":"int"},{"key":"page_views","type":"int"},
   {"key":"units_ordered","type":"int"},{"key":"ordered_product_sales","type":"number"},{"key":"buy_box_pct","type":"percent"},{"key":"unit_session_pct","type":"percent"},
   {"key":"impressions","type":"int"},{"key":"clicks","type":"int"}]',
   ARRAY['date','asin'], 'Business report – Detail page sales & traffic by child ASIN, theo ngày'),
 ('inventory_ledger','inventory_ledger',1,'inventory_ledger', '[
   {"key":"date","type":"date","required":true},{"key":"asin","type":"text","required":true},{"key":"sku","type":"text"},{"key":"fc","type":"text"},
   {"key":"available","type":"int"},{"key":"reserved","type":"int"},{"key":"inbound","type":"int"},{"key":"unfulfillable","type":"int"},{"key":"stranded","type":"int"},
   {"key":"aged_90","type":"int"},{"key":"aged_180","type":"int"},{"key":"aged_270","type":"int"},{"key":"aged_365","type":"int"}]',
   ARRAY['date','asin','sku','fc'], 'FBA inventory theo ngày × ASIN × SKU × FC')
ON CONFLICT (import_kind) DO UPDATE SET feed_key = EXCLUDED.feed_key, schema_version = EXCLUDED.schema_version, target_table = EXCLUDED.target_table,
  fields = EXCLUDED.fields, natural_key = EXCLUDED.natural_key, description = EXCLUDED.description;

ALTER TABLE public.ingest_feed_specs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ingest_feed_specs_select ON public.ingest_feed_specs;
CREATE POLICY ingest_feed_specs_select ON public.ingest_feed_specs FOR SELECT TO authenticated USING (true);

-- ------------------------------------------------------------
-- 2. Staging
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ingest_batches (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  marketplace    TEXT NOT NULL,
  import_kind    TEXT NOT NULL REFERENCES public.ingest_feed_specs(import_kind),
  feed_key       TEXT NOT NULL REFERENCES public.data_feeds(feed_key),
  schema_version INT  NOT NULL,
  source_id      UUID REFERENCES public.data_sources(id) ON DELETE SET NULL,
  filename       TEXT,
  file_hash      TEXT NOT NULL,
  column_map     JSONB,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','validated','committed','failed')),
  rows_total     INT NOT NULL DEFAULT 0,
  rows_valid     INT NOT NULL DEFAULT 0,
  rows_invalid   INT NOT NULL DEFAULT 0,
  rows_inserted  INT NOT NULL DEFAULT 0,
  rows_updated   INT NOT NULL DEFAULT 0,
  rows_skipped   INT NOT NULL DEFAULT 0,
  rows_error     INT NOT NULL DEFAULT 0,
  summary        JSONB,
  run_id         UUID REFERENCES public.ingestion_runs(id) ON DELETE SET NULL,
  created_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  committed_at   TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ingest_batches_committed_file ON public.ingest_batches(tenant_id, import_kind, file_hash) WHERE status = 'committed';
CREATE INDEX IF NOT EXISTS idx_ingest_batches_tenant ON public.ingest_batches(tenant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ingest_rows (
  batch_id   UUID NOT NULL REFERENCES public.ingest_batches(id) ON DELETE CASCADE,
  row_no     INT  NOT NULL,
  raw        JSONB NOT NULL,
  normalized JSONB,
  row_hash   TEXT,
  valid      BOOLEAN NOT NULL DEFAULT false,
  error      TEXT,
  warning    TEXT,
  outcome    TEXT CHECK (outcome IN ('inserted','updated','skipped','error')),
  PRIMARY KEY (batch_id, row_no)
);

ALTER TABLE public.ingest_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingest_rows ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ingest_batches_select ON public.ingest_batches;
CREATE POLICY ingest_batches_select ON public.ingest_batches FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
DROP POLICY IF EXISTS ingest_rows_select ON public.ingest_rows;
CREATE POLICY ingest_rows_select ON public.ingest_rows FOR SELECT TO authenticated
  USING (batch_id IN (SELECT b.id FROM public.ingest_batches b WHERE b.tenant_id IN (SELECT public.my_tenant_ids())));

-- ------------------------------------------------------------
-- 3. Parse helpers (IMMUTABLE, không ném lỗi — trả NULL khi không parse được)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_parse_number(v TEXT) RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s TEXT;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  s := trim(v);
  IF s = '' OR s IN ('-', '—', 'N/A', 'n/a', 'NA') THEN RETURN NULL; END IF;
  s := regexp_replace(s, '[^0-9,.\-]', '', 'g');          -- bỏ $ € % khoảng trắng
  IF s ~ '^\-?\d{1,3}(\.\d{3})+(,\d+)?$' THEN               -- 1.234,56 (EU)
    s := replace(replace(s, '.', ''), ',', '.');
  ELSE
    s := replace(s, ',', '');                               -- 1,234.56 (US)
  END IF;
  IF s !~ '^\-?\d*\.?\d+$' THEN RETURN NULL; END IF;
  RETURN s::numeric;
EXCEPTION WHEN others THEN RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION public.ingest_parse_date(v TEXT) RETURNS DATE LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s TEXT;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  s := trim(v);
  IF s = '' THEN RETURN NULL; END IF;
  IF s ~ '^\d{4}-\d{2}-\d{2}' THEN RETURN left(s, 10)::date; END IF;           -- ISO / timestamp
  IF s ~ '^\d{1,2}/\d{1,2}/\d{4}' THEN RETURN to_date(split_part(s, ' ', 1), 'MM/DD/YYYY'); END IF; -- Amazon US
  IF s ~ '^\d{1,2}-\d{1,2}-\d{4}' THEN RETURN to_date(split_part(s, ' ', 1), 'DD-MM-YYYY'); END IF;
  IF s ~ '^[A-Za-z]{3} \d{1,2}, \d{4}' THEN RETURN to_date(s, 'Mon DD, YYYY'); END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN NULL;
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
          ELSIF d > CURRENT_DATE + 1 THEN errs := array_append(errs, k || ': ngày trong tương lai');
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

  RETURN res || jsonb_build_object('_ok', cardinality(errs) = 0,
    '_err', NULLIF(array_to_string(errs, '; '), ''), '_warn', NULLIF(array_to_string(warns, '; '), ''));
END; $$;

-- ------------------------------------------------------------
-- 4. Quyền
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_assert_permission(p_tenant UUID) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF; -- service role / SQL editor / test
  IF NOT public.has_permission(p_tenant, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền nhập dữ liệu (data.import)'; END IF;
END; $$;

-- ------------------------------------------------------------
-- 5. ingest_open — mở batch (idempotent theo file_hash)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_open(p_tenant UUID, p_kind TEXT, p_filename TEXT, p_file_hash TEXT, p_column_map JSONB DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sp RECORD; b RECORD; mk TEXT; sid UUID;
BEGIN
  PERFORM public.ingest_assert_permission(p_tenant);
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

-- ------------------------------------------------------------
-- 6. ingest_add_rows — nhận dòng thô (đã map cột → key), validate từng dòng
--    p_rows: [{"order_id":"...","asin":"..."}...]; p_offset: số thứ tự dòng đầu (để gửi theo chunk)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_add_rows(p_batch UUID, p_rows JSONB, p_offset INT DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b RECORD; r JSONB; i INT := 0; nrm JSONB; n_ok INT := 0; n_bad INT := 0; h TEXT; biz JSONB;
BEGIN
  SELECT * INTO b FROM public.ingest_batches WHERE id = p_batch;
  IF b.id IS NULL THEN RAISE EXCEPTION 'Batch không tồn tại'; END IF;
  PERFORM public.ingest_assert_permission(b.tenant_id);
  IF b.status NOT IN ('open','validated') THEN RAISE EXCEPTION 'Batch đã % — không thêm dòng được', b.status; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'p_rows phải là mảng'; END IF;
  IF jsonb_array_length(p_rows) > 2000 THEN RAISE EXCEPTION 'Tối đa 2000 dòng / lần gọi'; END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    nrm := public.ingest_normalize_row(b.import_kind, r);
    biz := nrm - '_ok' - '_err' - '_warn';
    h := md5(b.import_kind || ':' || b.schema_version || ':' || biz::text);
    INSERT INTO public.ingest_rows (batch_id, row_no, raw, normalized, row_hash, valid, error, warning)
    VALUES (p_batch, p_offset + i, r, biz, h, (nrm->>'_ok')::boolean, nrm->>'_err', nrm->>'_warn')
    ON CONFLICT (batch_id, row_no) DO UPDATE SET raw = EXCLUDED.raw, normalized = EXCLUDED.normalized, row_hash = EXCLUDED.row_hash,
      valid = EXCLUDED.valid, error = EXCLUDED.error, warning = EXCLUDED.warning;
    IF (nrm->>'_ok')::boolean THEN n_ok := n_ok + 1; ELSE n_bad := n_bad + 1; END IF;
  END LOOP;

  UPDATE public.ingest_batches SET status = 'open',
    rows_total = (SELECT count(*) FROM public.ingest_rows WHERE batch_id = p_batch),
    rows_valid = (SELECT count(*) FROM public.ingest_rows WHERE batch_id = p_batch AND valid),
    rows_invalid = (SELECT count(*) FROM public.ingest_rows WHERE batch_id = p_batch AND NOT valid)
  WHERE id = p_batch;
  RETURN jsonb_build_object('added', i, 'valid', n_ok, 'invalid', n_bad);
END; $$;

-- ------------------------------------------------------------
-- 7. ingest_dry_run — tổng hợp, so với dữ liệu hiện có, KHÔNG ghi bảng canonical
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_dry_run(p_batch UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b RECORD; dk TEXT; d_min DATE; d_max DATE; n_asin INT; unknown_asins TEXT[]; dup_in_file INT; existing_days INT := 0; errs JSONB; res JSONB;
BEGIN
  SELECT * INTO b FROM public.ingest_batches WHERE id = p_batch;
  IF b.id IS NULL THEN RAISE EXCEPTION 'Batch không tồn tại'; END IF;
  PERFORM public.ingest_assert_permission(b.tenant_id);
  IF b.status = 'committed' THEN RAISE EXCEPTION 'Batch đã commit'; END IF;

  dk := CASE b.import_kind WHEN 'orders' THEN 'order_date' WHEN 'returns' THEN 'return_date' WHEN 'promotions' THEN 'start_at' ELSE 'date' END;
  EXECUTE format('SELECT min((normalized->>%L)::date), max((normalized->>%L)::date) FROM public.ingest_rows WHERE batch_id = $1 AND valid', dk, dk) INTO d_min, d_max USING p_batch;

  SELECT count(DISTINCT normalized->>'asin') INTO n_asin FROM public.ingest_rows WHERE batch_id = p_batch AND valid AND normalized ? 'asin';
  SELECT array_agg(DISTINCT a ORDER BY a) INTO unknown_asins FROM (
    SELECT normalized->>'asin' a FROM public.ingest_rows WHERE batch_id = p_batch AND valid AND normalized ? 'asin'
    EXCEPT SELECT asin FROM public.amazon_skus WHERE tenant_id = b.tenant_id) x;
  IF b.import_kind = 'promotions' THEN
    SELECT array_agg(DISTINCT a ORDER BY a) INTO unknown_asins FROM (
      SELECT jsonb_array_elements_text(normalized->'asins') a FROM public.ingest_rows WHERE batch_id = p_batch AND valid
      EXCEPT SELECT asin FROM public.amazon_skus WHERE tenant_id = b.tenant_id) x;
  END IF;
  SELECT count(*) - count(DISTINCT row_hash) INTO dup_in_file FROM public.ingest_rows WHERE batch_id = p_batch AND valid;

  -- đã có dữ liệu trong khoảng ngày này? (cảnh báo ghi đè)
  IF d_min IS NOT NULL THEN
    CASE b.import_kind
      WHEN 'orders' THEN SELECT count(DISTINCT order_date) INTO existing_days FROM public.orders WHERE tenant_id = b.tenant_id AND order_date BETWEEN d_min AND d_max;
      WHEN 'returns' THEN SELECT count(DISTINCT return_date) INTO existing_days FROM public.returns WHERE tenant_id = b.tenant_id AND return_date BETWEEN d_min AND d_max;
      WHEN 'ads' THEN SELECT count(DISTINCT date) INTO existing_days FROM public.ad_daily WHERE tenant_id = b.tenant_id AND date BETWEEN d_min AND d_max;
      WHEN 'search_terms' THEN SELECT count(DISTINCT date) INTO existing_days FROM public.search_terms WHERE tenant_id = b.tenant_id AND date BETWEEN d_min AND d_max;
      WHEN 'traffic' THEN SELECT count(DISTINCT date) INTO existing_days FROM public.traffic_daily WHERE tenant_id = b.tenant_id AND date BETWEEN d_min AND d_max;
      WHEN 'inventory_ledger' THEN SELECT count(DISTINCT date) INTO existing_days FROM public.inventory_ledger WHERE tenant_id = b.tenant_id AND date BETWEEN d_min AND d_max;
      ELSE existing_days := 0;
    END CASE;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('row', row_no, 'error', error) ORDER BY row_no), '[]'::jsonb) INTO errs
  FROM (SELECT row_no, error FROM public.ingest_rows WHERE batch_id = p_batch AND NOT valid ORDER BY row_no LIMIT 200) e;

  res := jsonb_build_object(
    'batch_id', p_batch, 'import_kind', b.import_kind, 'feed_key', b.feed_key, 'schema_version', b.schema_version,
    'rows_total', b.rows_total, 'rows_valid', b.rows_valid, 'rows_invalid', b.rows_invalid,
    'date_min', d_min, 'date_max', d_max, 'distinct_asins', n_asin,
    'unknown_asins', COALESCE(to_jsonb(unknown_asins), '[]'::jsonb), 'unknown_asin_count', COALESCE(cardinality(unknown_asins), 0),
    'duplicate_rows_in_file', dup_in_file, 'existing_days_in_range', existing_days,
    'errors', errs, 'can_commit', b.rows_valid > 0);
  UPDATE public.ingest_batches SET status = 'validated', summary = res WHERE id = p_batch;
  RETURN res;
END; $$;

-- ------------------------------------------------------------
-- 8. ingest_commit — ghi canonical từng dòng (savepoint per row), ingestion_runs, derive snapshots
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_commit(p_batch UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  b RECORD; r RECORD; n JSONB; ins BOOLEAN; touched BOOLEAN;
  n_ins INT := 0; n_upd INT := 0; n_skip INT := 0; n_err INT := 0; errs JSONB := '[]'::jsonb;
  d_min DATE; d_max DATE; run UUID; st TEXT; lvl TEXT; ck TEXT; gk TEXT; kk TEXT; derived JSONB; t0 TIMESTAMPTZ := clock_timestamp();
BEGIN
  SELECT * INTO b FROM public.ingest_batches WHERE id = p_batch FOR UPDATE;
  IF b.id IS NULL THEN RAISE EXCEPTION 'Batch không tồn tại'; END IF;
  PERFORM public.ingest_assert_permission(b.tenant_id);
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

GRANT EXECUTE ON FUNCTION public.ingest_open(UUID, TEXT, TEXT, TEXT, JSONB), public.ingest_add_rows(UUID, JSONB, INT),
  public.ingest_dry_run(UUID), public.ingest_commit(UUID), public.ingest_normalize_row(TEXT, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 9. Đóng đường ghi trực tiếp từ trình duyệt vào sku_daily_snapshots
--    (UI đã chuyển orders/ads sang RPC; sales/inventory/fees/catalog/cogs/reviews vẫn ghi bảng riêng của chúng — sẽ đóng ở bước sau)
-- ------------------------------------------------------------
DROP POLICY IF EXISTS snap_write ON public.sku_daily_snapshots;

-- Self-check
DO $$
BEGIN
  RAISE NOTICE '021 self-check: specs=% (kỳ vọng 7), snap_write policy còn? %',
    (SELECT count(*) FROM public.ingest_feed_specs),
    (SELECT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'sku_daily_snapshots' AND policyname = 'snap_write'));
END $$;
