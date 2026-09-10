-- ============================================================
-- Vexim Amazon Managed Operations — dữ liệu mẫu (pilot)
-- File 2/2: chạy SAU 001_schema.sql. Chạy lại được (upsert theo asin).
-- ============================================================

INSERT INTO public.amazon_skus
  (asin, sku, title, cogs, current_price, list_price, fee_per_unit, referral_fee_pct,
   sales_last_30d, avg_order_value, margin_delta, inventory_qty, reorder_point,
   stockout_risk_score, price_volatility)
VALUES
  ('B08N5RRNJC', 'VX-BAMBOO-CB-01', 'Thớt tre kháng khuẩn Vexim 3 món',              6.80, 24.99, 29.99, 5.40, 15.00, 420, 26.10,  1.20, 1350,  600, 18.5, 3.2),
  ('B07XJ8C8F5', 'VX-COCO-BOWL-04', 'Bát gáo dừa tự nhiên set 4 kèm thìa gỗ',       4.10, 19.95, 22.95, 4.90, 15.00, 610, 20.30, -0.80,  240,  700, 82.0, 5.6),
  ('B09KLM2ZQ1', 'VX-RATTAN-BSK-M', 'Giỏ mây đan tay đựng đồ size M',               9.50, 34.99, 39.99, 7.80, 15.00, 185, 35.20,  0.40,  520,  250, 24.0, 2.1),
  ('B0BQ7T4H2R', 'VX-CASHEW-W320', 'Hạt điều rang muối Bình Phước W320 – 1 lb',    5.20, 15.99, 17.99, 3.95, 8.00,  980, 16.40, -2.10,  410, 1200, 91.5, 8.4),
  ('B0CFH9JW7N', 'VX-LOTUS-TEA-50', 'Trà sen Tây Hồ túi lọc 50 gói',                3.30, 13.49, 14.99, 3.60, 15.00, 260, 13.90,  0.00,  880,  300, 12.0, 1.4),
  ('B0D2X3P8LK', 'VX-CERAMIC-MUG', 'Cốc gốm Bát Tràng men rạn 350ml (bộ 2)',        7.20, 27.50, 32.00, 6.30, 15.00,  95, 28.00,  1.90,  760,  150,  6.5, 4.0),
  ('B0BW5RK9ZT', 'VX-SILK-SCARF', 'Khăn lụa tơ tằm Vạn Phúc 90x180cm',              11.00, 45.00, 49.00, 5.10, 17.00, 140, 45.80,  3.10,  130,  200, 68.0, 6.9),
  ('B09Y6D7NMB', 'VX-COFFEE-ROB-1KG', 'Cà phê Robusta Buôn Ma Thuột rang mộc 1kg', 6.40, 21.99, 24.99, 6.10, 8.00,  730, 22.60, -1.30,  310,  900, 88.0, 7.7)
ON CONFLICT (asin, marketplace) DO UPDATE SET
  sku = EXCLUDED.sku, title = EXCLUDED.title, cogs = EXCLUDED.cogs,
  current_price = EXCLUDED.current_price, list_price = EXCLUDED.list_price,
  fee_per_unit = EXCLUDED.fee_per_unit, referral_fee_pct = EXCLUDED.referral_fee_pct,
  sales_last_30d = EXCLUDED.sales_last_30d, avg_order_value = EXCLUDED.avg_order_value,
  margin_delta = EXCLUDED.margin_delta, inventory_qty = EXCLUDED.inventory_qty,
  reorder_point = EXCLUDED.reorder_point, stockout_risk_score = EXCLUDED.stockout_risk_score,
  price_volatility = EXCLUDED.price_volatility, last_ingested_at = now();

-- Review mẫu
INSERT INTO public.raw_reviews (asin, reviewer_id, rating, title, body, verified_purchase, source, reviewed_at)
SELECT * FROM (VALUES
  ('B07XJ8C8F5', 'r-1001', 5, 'Beautiful bowls',          'Love the natural look, perfect for smoothie bowls.',              true,  'manual', now() - interval '3 days'),
  ('B07XJ8C8F5', 'r-1002', 2, 'One bowl cracked',         'One of the four arrived with a crack. Packaging could be better.', true,  'manual', now() - interval '9 days'),
  ('B0BQ7T4H2R', 'r-1003', 4, 'Fresh and crunchy',        'Great taste, a bit salty for me.',                                true,  'manual', now() - interval '1 day'),
  ('B0BQ7T4H2R', 'r-1004', 1, 'Bag arrived open',         'Seal was broken, had to throw it away.',                          true,  'manual', now() - interval '5 days'),
  ('B08N5RRNJC', 'r-1005', 5, 'Solid cutting boards',     'Thick, sturdy, no warping after a month.',                        true,  'manual', now() - interval '12 days'),
  ('B0BW5RK9ZT', 'r-1006', 3, 'Nice but thin',            'Colors are gorgeous but the silk is thinner than expected.',     false, 'manual', now() - interval '7 days')
) AS v(asin, reviewer_id, rating, title, body, verified_purchase, source, reviewed_at)
WHERE NOT EXISTS (
  SELECT 1 FROM public.raw_reviews r WHERE r.reviewer_id = v.reviewer_id
);

-- Gợi ý mẫu (liên kết sku_id theo asin)
INSERT INTO public.recommendations
  (sku_id, asin, type, title, rationale, current_value, proposed_value, expected_impact,
   risk_score, required_approval_level, status)
SELECT s.id, v.asin, v.type, v.title, v.rationale, v.current_value, v.proposed_value,
       v.expected_impact, v.risk_score, v.level, v.status
FROM (VALUES
  ('B0BQ7T4H2R', 'replenish',       'Nhập thêm 1.500 đơn vị hạt điều W320',
     'Tồn 410, bán 980/30 ngày → chỉ còn ~12 ngày hàng. Rủi ro hết hàng 91.5.',
     410::numeric, 1500::numeric, 5200::numeric, 35::numeric, 'L1', 'pending_approval'),
  ('B07XJ8C8F5', 'replenish',       'Nhập thêm 800 đơn vị bát gáo dừa',
     'Tồn 240 dưới điểm đặt hàng lại 700; tốc độ bán 20/ngày.',
     240, 800, 3100, 30, 'L1', 'pending_approval'),
  ('B09Y6D7NMB', 'replenish',       'Nhập thêm 1.000 kg cà phê Robusta',
     'Còn ~13 ngày hàng, lead time nhà cung cấp 21 ngày.',
     310, 1000, 4700, 40, 'L1', 'draft'),
  ('B0D2X3P8LK', 'price_adjust',    'Giảm giá cốc gốm 27.50 → 24.99',
     'Tồn kho 760 với tốc độ bán 3/ngày (~8 tháng). Giảm giá để tăng vòng quay.',
     27.50, 24.99, 650, 55, 'L2', 'pending_approval'),
  ('B08N5RRNJC', 'price_adjust',    'Tăng giá thớt tre 24.99 → 26.49',
     'Buy Box ổn định 30 ngày, đối thủ gần nhất 27.99, biên độ giá thấp.',
     24.99, 26.49, 630, 45, 'L1', 'draft'),
  ('B07XJ8C8F5', 'review_response', 'Phản hồi review 2★ về bát bị nứt',
     'Review verified có nhắc lỗi đóng gói; cần phản hồi và mở ticket QC.',
     NULL, NULL, NULL, 10, 'L0', 'approved'),
  ('B0BW5RK9ZT', 'inventory_transfer', 'Chuyển 60 khăn lụa từ FBM sang FBA',
     'Tồn FBA 130 với rủi ro hết hàng 68; hàng FBM còn dư.',
     130, 190, 900, 25, 'L1', 'draft')
) AS v(asin, type, title, rationale, current_value, proposed_value, expected_impact, risk_score, level, status)
JOIN public.amazon_skus s ON s.asin = v.asin AND s.marketplace = 'US'
WHERE NOT EXISTS (
  SELECT 1 FROM public.recommendations r WHERE r.asin = v.asin AND r.type = v.type AND r.title = v.title
);

-- Ngoại lệ mẫu
INSERT INTO public.exceptions (recommendation_id, asin, code, message)
SELECT r.id, r.asin, 'P1', 'Rủi ro hết hàng > 90 nhưng chưa có PO được duyệt'
FROM public.recommendations r
WHERE r.asin = 'B0BQ7T4H2R' AND r.type = 'replenish'
  AND NOT EXISTS (SELECT 1 FROM public.exceptions e WHERE e.recommendation_id = r.id);

INSERT INTO public.exceptions (recommendation_id, asin, code, message)
SELECT r.id, r.asin, 'P2', 'Giảm giá > 5% cần admin (L2) phê duyệt'
FROM public.recommendations r
WHERE r.asin = 'B0D2X3P8LK' AND r.type = 'price_adjust'
  AND NOT EXISTS (SELECT 1 FROM public.exceptions e WHERE e.recommendation_id = r.id);

-- Kiểm tra nhanh
SELECT asin, title, current_price, contribution_profit, inventory_qty, stockout_risk_score
FROM public.amazon_skus ORDER BY contribution_profit DESC;
