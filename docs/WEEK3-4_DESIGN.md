# Tuần 3‑4 – Thiết kế: Daily snapshot · Metric layer · Chi tiết ASIN

_2026‑09‑10 · Trạng thái: **đã build** (commit tuần 3‑4)_

## 1. Vấn đề cần giải

Hệ thống hiện chỉ có **trạng thái hiện tại** của SKU (`amazon_skus`: giá, tồn, doanh số 30 ngày gộp). Không có lịch sử → không tính được:

| Chỉ số | Cần gì | Dùng cho mắt xích |
|---|---|---|
| Velocity 7/30 ngày & thay đổi | đơn vị bán **theo ngày** | Risk (tuần 5‑6), Forecast (7‑8) |
| Price volatility | giá **theo ngày** | Risk |
| Margin Δ vs baseline | CP/đơn vị theo ngày | Risk, Profit bridge |
| Days of cover chính xác, ETA hết hàng | tồn kho theo ngày + velocity | Replenishment |
| TACoS / ACoS / CVR | ad spend, ad sales, sessions theo ngày | Profit bridge |
| Đo lường trước/sau action | mọi thứ trên theo ngày | Measurement (12‑14) |

→ Cần **một bảng sự thật theo ngày**: `sku_daily_snapshots`, grain = (sku, ngày).

## 2. Nguồn dữ liệu theo ngày – thực tế có gì?

Chưa có SP‑API (cần Developer registration, ~2‑4 tuần). Trong pilot, dữ liệu theo ngày lấy được **hợp lệ, không scraping** từ:

| Nguồn | Cho cột nào | Lịch sử ngược? | Cách lấy |
|---|---|---|---|
| **All Orders report** (Seller Central → Reports → Fulfillment → All Orders, by order date, tối đa 30 ngày/file) | `units`, `revenue`, `avg_price` theo ngày & ASIN | ✅ tới 2 năm | CSV, gộp theo `purchase-date` + `asin`, bỏ `Cancelled` |
| **Sponsored Products – Advertised product report** (Ads console, granularity Daily) | `ad_spend`, `ad_sales`, `clicks`, `impressions` | ✅ 60‑90 ngày | CSV |
| **Business Report by Child Item** (đã có, tuần 1‑2) | `sessions`, `units` 30 ngày gộp | ❌ chỉ tổng | vẫn dùng cho gate |
| **Snapshot tự động hằng ngày** (pg_cron trong Supabase) | `price`, `cogs`, `fee`, `inventory_qty`, `contribution_profit` tại thời điểm chụp | ❌ chỉ từ ngày bật | `capture_daily_snapshots()` 03:00 UTC + nút chụp tay |

Kết luận: **flow** (bán/ads) có lịch sử ngay nhờ import; **state** (tồn kho, giá) tích luỹ từ ngày bật. Biểu đồ tồn kho sẽ "mọc" dần – chấp nhận được, vì forecast cần velocity (có ngay) hơn là lịch sử tồn.

## 3. Mô hình dữ liệu

### 3.1 `sku_daily_snapshots`
```
PK (sku_id, date)   · tenant_id, asin (denormalize để import nhanh)
-- state (từ capture)
price, cogs, fee_per_unit, referral_fee_pct, contribution_profit, inventory_qty, inventory_inbound, reorder_point
-- flow (từ import)
units, revenue, sessions, page_views, ad_spend, ad_sales, ad_clicks, ad_impressions
-- meta
sources jsonb  {"state":"cron|manual","orders":"csv","ads":"csv"}   · created_at, updated_at
```
Quy ước quan trọng: **NULL = chưa có dữ liệu**, **0 = có dữ liệu và bằng 0**. Import đơn hàng cho ngày không có đơn phải ghi `units = 0` cho các ASIN trong danh mục (trong khoảng ngày của file) để velocity không bị thổi phồng. Metric chỉ tính trên các ngày có `units IS NOT NULL` và báo `coverage_days` để UI cảnh báo thiếu.

Mỗi nguồn chỉ ghi **cột của mình** (PostgREST upsert chỉ SET các cột có trong payload) → import ads không xoá units và ngược lại.

### 3.2 `reconciliation_checks` – gate tuần 3‑4
Người vận hành nhập tổng Seller Central (doanh thu, đơn vị) cho một khoảng ngày; hệ thống so với tổng snapshot; lệch ≤ `policy.revenue_tolerance_pct` → đạt. Lưu lại từng lần để có bằng chứng "dữ liệu đối soát" cuối pilot.

### 3.3 Đồng bộ ngược về `amazon_skus`
`amazon_skus` vẫn là "trạng thái hiện tại" mà mọi màn hình dùng. Sau import đơn hàng, RPC `refresh_sku_rolling_from_snapshots(t)` cập nhật `sales_last_30d`, `revenue_last_30d` **chỉ khi** có ≥ 20/30 ngày dữ liệu – tránh ghi đè số Business Report bằng số thiếu.

## 4. Metric layer – định nghĩa

Một hàm SQL `sku_metrics(t, asof default today, only_sku default null)` (SECURITY INVOKER → RLS áp dụng) trả về mỗi SKU:

| Metric | Công thức | Ghi chú |
|---|---|---|
| `velocity_7d`, `velocity_30d` | Σ units / số ngày có dữ liệu trong cửa sổ | đơn vị/ngày |
| `velocity_change_pct` | (v7 − v30) / v30 | đầu vào risk "velocity" |
| `coverage_days_30` | số ngày có `units` trong 30 ngày | < 20 → UI gắn cờ "dữ liệu mỏng" |
| `price_avg_30`, `price_volatility_pct` | stddev(price)/avg(price) × 100 | price = snapshot state, fallback revenue/units | 
| `cp_unit_now`, `cp_margin_now_pct` | từ `amazon_skus` | |
| `cp_margin_baseline_pct` | từ `kpi_baseline.snapshot` (nếu đã chốt) else trung bình 30 ngày đầu có dữ liệu | |
| `margin_delta_pts` | now − baseline | đầu vào risk "margin Δ" |
| `days_of_cover` | inventory / (v7 ‖ v30 ‖ sales_last_30d/30) | |
| `stockout_eta` | today + days_of_cover | |
| `inventory_health` | DoC so với (lead_time + safety_stock) từ policy: `<1×` đỏ, `<1.5×` vàng | đầu vào risk "inventory" |
| `tacos_30`, `acos_30`, `cvr_30` | ad_spend/revenue · ad_spend/ad_sales · units/sessions | NULL khi thiếu nguồn |
| `last_sale_date`, `days_since_last_sale` | | aging |

`tenant_daily(t, days)` trả về chuỗi theo ngày cấp brand: units, revenue, cp (= Σ units × cp_unit ngày đó), ad_spend, inventory_units → biểu đồ Tổng quan.

Tuần 5‑6 sẽ chỉ cần **ghép 4 thành phần đã có** (margin_delta, inventory_health, velocity_change, volatility) với trọng số trong `policy_register.risk_weights` → risk score. Không phải làm lại dữ liệu.

## 5. Giao diện

### Tổng quan (bổ sung)
- **Xu hướng 30/90 ngày**: đường doanh thu & CP theo ngày, cột đơn vị; toggle 30/90.
- **Kết nối dữ liệu**: snapshot gần nhất, số ngày có dữ liệu bán/ads, lần import gần nhất mỗi loại, trạng thái SP‑API = "chưa kết nối (dùng CSV)", nút *Chụp snapshot hôm nay*.
- Bảng ASIN: tên sản phẩm → link `/skus/[id]`; thêm cột **Velocity 7d** và **ETA hết hàng** khi có metric.

### Chi tiết ASIN `/skus/[id]`
1. Header: tên, ASIN/SKU, trạng thái, nhà cung cấp, lead time; nút *Sửa* (operator+).
2. 6 tile: Giá · CP/đv & biên · Bán 7d/30d (+Δ%) · Doanh thu 30d · Tồn & DoC · TACoS/CVR.
3. Biểu đồ: (a) đơn vị/ngày + MA7; (b) giá & CP/đv; (c) tồn kho + đường ROP + ETA; (d) ad spend & TACoS (nếu có).
4. Tab: Gợi ý của ASIN · Ngoại lệ · Review · Lịch sử COGS · Bảng snapshot 30 ngày.
5. Modal sửa: giá, phí, referral, ROP, lead time, NCC, trạng thái; **COGS mới → thêm dòng `cogs_history`** (không sửa trực tiếp).

### Nhập dữ liệu (bổ sung)
- Loại **Đơn hàng (All Orders)**: gộp theo ngày+ASIN, bỏ Cancelled, ghi 0 cho ASIN không có đơn trong khoảng ngày file; sau import gọi `refresh_sku_rolling_from_snapshots`.
- Loại **Quảng cáo (SP Advertised product, daily)**.
- Thẻ **Đối soát**: nhập khoảng ngày + tổng Seller Central → kết quả lệch % và đạt/không; lịch sử.

## 6. Quyết định & đánh đổi

| Quyết định | Lý do | Đánh đổi |
|---|---|---|
| Ngày bucket theo **UTC** của `purchase-date` | đơn giản, nhất quán với Ads report (UTC) | lệch ≤ 1 ngày so với báo cáo theo giờ marketplace; đối soát dùng khoảng ≥ 7 ngày để triệt tiêu |
| Metric tính **on‑the‑fly bằng SQL function**, không materialize | pilot ≤ vài trăm SKU × 365 ngày – nhanh đủ; không lo stale | khi scale cần materialized view + refresh |
| pg_cron trong Supabase thay vì cron ngoài | không thêm hạ tầng; owner chỉ chạy SQL | nếu project không bật được `pg_cron`, dùng nút chụp tay / Vercel cron sau |
| Không backfill "giả" lịch sử tồn kho | không bịa dữ liệu; đúng nguyên tắc báo cáo bằng dữ liệu thật | biểu đồ tồn kho trống 1‑2 tuần đầu |
| Recharts cho biểu đồ | nhẹ, phổ biến, SSR‑safe với `'use client'` | thêm 1 dependency |

## 7. Gate tuần 3‑4 (hiển thị trên Tổng quan)
- ≥ 20/30 ngày có dữ liệu bán cho ≥ 90% doanh thu (coverage).
- Ít nhất 1 lần đối soát đạt trong 14 ngày gần nhất (lệch ≤ tolerance).
- Snapshot state chạy hằng ngày (snapshot gần nhất ≤ 2 ngày).

## 8. Việc làm trong sprint này
- [x] `006_snapshots_metrics.sql`: bảng, index, RLS, `capture_daily_snapshots`, pg_cron, `sku_metrics`, `tenant_daily`, `refresh_sku_rolling_from_snapshots`, `reconciliation_checks` + `run_reconciliation`, view kết nối dữ liệu.
- [x] Import: schema `orders`, `ads`; logic gộp; ghi 0; refresh rolling.
- [x] Đối soát UI.
- [x] Recharts + components biểu đồ.
- [x] Tổng quan: xu hướng, kết nối dữ liệu, link & cột mới.
- [x] `/skus/[id]` đầy đủ + modal sửa.
- [x] Docs & gate.
