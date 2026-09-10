-- ============================================================
-- 002b — Seed demo THEO TENANT (thay 002_seed.sql lỗi thời). Idempotent.
-- Cách dùng: sửa v_slug bên dưới thành slug tenant đã tồn tại rồi Run.
-- Chỉ tạo dữ liệu DEMO (5 SKU, snapshot 30 ngày, 3 review). Không tạo action/publish.
-- ============================================================
DO $$
DECLARE v_slug TEXT := 'demo';   -- <== đổi thành slug tenant của bạn
        t UUID; k RECORD; d INT; base NUMERIC;
BEGIN
  SELECT id INTO t FROM public.tenants WHERE slug = v_slug;
  IF t IS NULL THEN RAISE EXCEPTION 'Không có tenant slug=%. Tạo tenant trước (Settings → Thành viên).', v_slug; END IF;

  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, cogs, current_price, list_price, fee_per_unit, referral_fee_pct, inventory_qty, reorder_point, lead_time_days, supplier, cogs_source, fee_source)
  VALUES
    (t,'B0DEMO00001','DEMO-CB-01','[DEMO] Thớt tre kháng khuẩn 3 món','US',6.80,24.99,29.99,5.40,15,420,150,45,'Demo Supplier','manual','manual'),
    (t,'B0DEMO00002','DEMO-BOWL-04','[DEMO] Bát gáo dừa set 4','US',4.10,19.95,22.95,4.90,15,80,120,45,'Demo Supplier','manual','manual'),
    (t,'B0DEMO00003','DEMO-STRAW-50','[DEMO] Ống hút tre 50 cái','US',2.30,12.99,14.99,3.80,15,900,200,30,'Demo Supplier','manual','manual'),
    (t,'B0DEMO00004','DEMO-BAG-01','[DEMO] Túi cói đi chợ','US',5.50,21.50,NULL,5.10,15,15,100,60,'Demo Supplier','manual','manual'),
    (t,'B0DEMO00005','DEMO-CANDLE-02','[DEMO] Nến sáp đậu nành 2 hũ','US',7.20,26.00,29.00,6.10,15,260,90,30,'Demo Supplier','manual','manual')
  ON CONFLICT (tenant_id, asin, marketplace) DO UPDATE SET title = EXCLUDED.title, cogs = EXCLUDED.cogs, current_price = EXCLUDED.current_price;

  -- 30 ngày snapshot flow (units/revenue/sessions) — đánh dấu nguồn 'seed_demo'
  FOR k IN SELECT id, asin, current_price, contribution_profit FROM public.amazon_skus WHERE tenant_id = t AND asin LIKE 'B0DEMO%' LOOP
    base := CASE k.asin WHEN 'B0DEMO00001' THEN 9 WHEN 'B0DEMO00002' THEN 4 WHEN 'B0DEMO00003' THEN 14 WHEN 'B0DEMO00004' THEN 2 ELSE 6 END;
    FOR d IN 0..29 LOOP
      INSERT INTO public.sku_daily_snapshots (sku_id, date, tenant_id, asin, price, contribution_profit, units, revenue, sessions, page_views, sources)
      VALUES (k.id, CURRENT_DATE - d, t, k.asin, k.current_price, k.contribution_profit,
              GREATEST(0, round(base + sin(d / 3.0) * base * 0.3 + (d % 4) - 1.5))::int,
              GREATEST(0, round(base + sin(d / 3.0) * base * 0.3 + (d % 4) - 1.5)) * k.current_price,
              (base * 12 + d % 7 * 5)::int, (base * 15 + d % 7 * 6)::int, '{"flow":"seed_demo"}'::jsonb)
      ON CONFLICT (sku_id, date) DO UPDATE SET units = EXCLUDED.units, revenue = EXCLUDED.revenue, sessions = EXCLUDED.sessions, page_views = EXCLUDED.page_views, sources = public.sku_daily_snapshots.sources || EXCLUDED.sources;
    END LOOP;
  END LOOP;

  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at)
  SELECT t, 'B0DEMO00002', 2, '[DEMO] Bát nứt sau 2 tuần', 'Một bát bị nứt, mùi dừa hơi nồng.', now() - interval '5 days'
  WHERE NOT EXISTS (SELECT 1 FROM public.raw_reviews WHERE tenant_id = t AND title = '[DEMO] Bát nứt sau 2 tuần');
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at)
  SELECT t, 'B0DEMO00001', 5, '[DEMO] Rất đẹp', 'Thớt chắc, dễ vệ sinh.', now() - interval '3 days'
  WHERE NOT EXISTS (SELECT 1 FROM public.raw_reviews WHERE tenant_id = t AND title = '[DEMO] Rất đẹp');
  INSERT INTO public.raw_reviews (tenant_id, asin, rating, title, body, reviewed_at)
  SELECT t, 'B0DEMO00004', 1, '[DEMO] Giao thiếu', 'Đặt 2 nhận 1, không ai trả lời.', now() - interval '1 day'
  WHERE NOT EXISTS (SELECT 1 FROM public.raw_reviews WHERE tenant_id = t AND title = '[DEMO] Giao thiếu');

  -- rolling 30 ngày (không gọi RPC vì SQL Editor chạy không có auth.uid())
  UPDATE public.amazon_skus k SET sales_last_30d = a.u, revenue_last_30d = a.r, sessions_last_30d = a.s, last_ingested_at = now()
  FROM (SELECT sku_id, SUM(units) u, SUM(revenue) r, SUM(sessions) s FROM public.sku_daily_snapshots WHERE tenant_id = t AND date > CURRENT_DATE - 30 GROUP BY sku_id) a
  WHERE a.sku_id = k.id;
  RAISE NOTICE 'Seed demo xong cho tenant % (%). Chạy run_rules(t) / run_forecasts nếu muốn có gợi ý ngay.', v_slug, t;
END $$;
