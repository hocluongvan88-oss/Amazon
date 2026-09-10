# Tuần 5‑6 – Thiết kế: Risk score · Rule engine · Profit bridge · SLA ngoại lệ

_2026‑09‑10 · Trạng thái: **đã build**_

## 1. Mục tiêu
Biến hệ thống từ **hiển thị** thành **đề xuất có kiểm soát**: mỗi ngày hệ thống tự nhìn dữ liệu, phát hiện vấn đề (detect), giải thích nguyên nhân (diagnose), đưa ra hành động đề xuất có `rationale` đọc hiểu được, gắn `risk_score` → cấp duyệt, và xếp vào hàng đợi có SLA. Con người vẫn quyết định.

Gate tuần 5‑6: **precision cảnh báo đủ dùng** (operator đánh dấu đúng/sai) và **operator giải thích được nguyên nhân** từ rationale.

## 2. Risk score tổng hợp – `compute_risk_score`

### 2.1 Nguyên tắc
- 0‑100, **cao = rủi ro cao** (nhất quán với `stockout_risk_score` hiện có).
- Tổng có trọng số của **4 thành phần**, mỗi thành phần 0‑100, trọng số từ `policy_register.risk_weights` (tuần 1‑2 đã có, mặc định 0.30 / 0.35 / 0.20 / 0.15).
- **Giải thích được**: lưu từng thành phần + lý do vào `amazon_skus.risk_components` (JSONB) để UI hiển thị "vì sao 78 điểm".
- **Thiếu dữ liệu ≠ rủi ro cao**: thành phần không tính được → bỏ ra khỏi mẫu số (chuẩn hoá lại trọng số), đồng thời ghi `data_confidence` (0‑1) = tổng trọng số các thành phần có dữ liệu.

### 2.2 Bốn thành phần

| Thành phần | Đầu vào (từ `sku_metrics`) | Ánh xạ → 0‑100 |
|---|---|---|
| **inventory_health** | `days_of_cover` (DoC) so với `need` = lead time + safety stock | DoC ≤ 0 → 100 · DoC = need → 60 · DoC = 1.5×need → 30 · DoC ≥ 3×need → 5 · tuyến tính giữa các mốc. Tồn dư (>6×need) → 25 (rủi ro vốn, nhẹ hơn hết hàng) |
| **margin_delta** | `margin_delta_pts` (biên hiện tại − baseline, điểm %) và `cp_margin_now_pct` so với `min_margin_pct` | Δ ≥ 0 → 10 · Δ = −2 → 35 · Δ = −5 → 65 · Δ ≤ −10 → 100. Nếu biên hiện tại < `min_margin_pct` → tối thiểu 70 (bất kể Δ). Không có baseline → dùng biên tuyệt đối: biên ≥ 25% → 10 · = min → 60 · ≤ 0 → 100 |
| **velocity** | `velocity_change_pct` (7d vs 30d), `days_since_last_sale` | Sụt: −10% → 20 · −30% → 55 · −50% → 85 · ≤ −70% → 100. Tăng đột biến > +80% → 40 (nguy cơ hết hàng sớm/đo sai). Không bán ≥ 7 ngày mà 30d có bán → 90 |
| **volatility** | `price_volatility_pct` (stddev/avg 30 ngày) | 0% → 0 · 3% → 30 · 8% → 65 · ≥ 15% → 100 |

Ánh xạ dùng hàm nội suy tuyến tính theo mốc `pl_interp(x, points[])` – dễ chỉnh, dễ giải thích.

### 2.3 Đầu ra
- `amazon_skus.risk_score` (mới), `risk_components` JSONB `{inventory:{score,doc,need,reason}, margin:{…}, velocity:{…}, volatility:{…}, confidence, computed_at}`.
- `stockout_risk_score` được **ghi lại = inventory_health** (thay số nhập tay) khi có dữ liệu → mọi màn hình hiện dùng cột này tự đúng.
- Lịch sử: `risk_history(sku_id, date, risk_score, components)` – để vẽ và để đo precision về sau.

## 3. Rule engine – `run_rules(t)`

### 3.1 Vòng đời
Chạy hằng ngày (pg_cron 03:30 UTC, sau snapshot) hoặc bấm tay. Mỗi lần: (1) tính lại risk cho mọi SKU active, (2) đánh giá từng rule, (3) sinh ngoại lệ / gợi ý **nếu chưa có cái đang mở cùng loại cho cùng SKU** (dedupe), (4) **tự đóng** ngoại lệ mà điều kiện không còn (auto‑resolve, ghi lý do "điều kiện hết"), (5) ghi `rule_runs` (bao nhiêu SKU, bao nhiêu mở/đóng, thời gian).

### 3.2 Bộ rule pilot

| Mã | Điều kiện (từ metrics + policy) | Sinh | P | Gợi ý kèm theo |
|---|---|---|---|---|
| `STOCKOUT_IMMINENT` | DoC < lead_time (không kịp nhập) | ngoại lệ | P0 nếu DoC < 7 · P1 nếu < lead_time | `replenish` qty = ceil(v7 × (lead_time + safety) + safety_stock − on_hand), min 0 |
| `BELOW_REORDER_POINT` | inventory < ROP và không thuộc rule trên | ngoại lệ | P2 | `replenish` |
| `OVERSTOCK` | DoC > 6 × need và inventory > 0 | ngoại lệ | P3 | `price_adjust` giảm ≤ `price_change_l2_pct`, giữ biên ≥ min_margin |
| `MARGIN_EROSION` | margin Δ ≤ −`margin_drop_p1_pct` hoặc biên < min_margin | ngoại lệ | P1 | `price_adjust` tăng để về biên min (tối đa `price_change_l2_pct`), kèm rationale nêu COGS/phí thay đổi |
| `VELOCITY_DROP` | v7 vs v30 ≤ −30% và u30 ≥ 30 đv | ngoại lệ | P2 | không tự gợi ý (cần chẩn đoán: giá/đối thủ/listing) – rationale nêu các nguyên nhân cần kiểm |
| `NO_SALES_7D` | không bán 7 ngày, 30d có ≥ 10 đv | ngoại lệ | P1 | không |
| `PRICE_VOLATILITY` | volatility ≥ 8% | ngoại lệ | P3 | không |
| `DATA_STALE` | snapshot/state > 3 ngày hoặc coverage < 20/30 | ngoại lệ cấp brand | P2 | không |

Mỗi gợi ý sinh ra: `type`, `current_value`, `proposed_value`, `expected_impact` (ước lượng đơn giản, ghi rõ công thức trong rationale), `risk_score` = risk SKU, cấp duyệt do trigger `assign_recommendation_level` (tuần 1‑2) tự gán từ policy. `rationale` là **văn bản tiếng Việt có số liệu**, ví dụ:

> Tồn 410 đv, bán 32,7 đv/ngày (7 ngày) → còn ~12,5 ngày; lead time 30 + safety 14 = 44 ngày cần. Đề xuất nhập 1.450 đv = 32,7 × 44 + 14 ngày an toàn − 410. Rủi ro 91 (tồn kho 100 · biên 20 · tốc độ 35 · biến động 10; độ tin cậy dữ liệu 100%).

### 3.3 Chống spam
- Dedupe theo (`sku_id`, `rule_code`) đang mở.
- `cooldown_days` (mặc định 7) sau khi ngoại lệ được đóng thủ công ("không đúng") → không mở lại cùng rule.
- Gợi ý chỉ sinh khi ngoại lệ mới mở (không lặp lại nếu đã có gợi ý mở cùng type cho SKU).

### 3.4 Precision (gate)
Ngoại lệ có `feedback` = `true_positive | false_positive | null` và `feedback_note`. Khi operator đóng thủ công phải chọn. View `v_rule_precision(rule_code, opened, tp, fp, precision)` → hiển thị ở Ngoại lệ và Đo lường sau này.

## 4. SLA ngoại lệ
- `policy_register.sla_hours` JSONB `{"P0":4,"P1":24,"P2":72,"P3":168}`.
- `exceptions` thêm: `rule_code`, `sku_id`, `assigned_to`, `due_at` (= created_at + SLA), `snoozed_until`, `auto_resolved`, `feedback`, `feedback_note`, `resolution_note`.
- View `v_exception_queue`: kèm `overdue` (now > due_at và chưa đóng), `hours_left`, tên SKU, metrics tóm tắt.
- UI: hàng đợi sắp xếp P → quá hạn → sắp hết hạn; gán người (dropdown thành viên), snooze 1/3/7 ngày, đóng có chọn đúng/sai + ghi chú; badge "quá hạn" trên Tổng quan.

## 5. Profit bridge
Phân rã Δ lợi nhuận góp phần **kỳ này vs kỳ trước** (mặc định 7 ngày gần nhất vs 7 ngày trước đó; chọn 14/28) theo từng ASIN rồi cộng brand. Với mỗi SKU, `CP = units × (price − cogs − fee − price×ref%)`. Dùng phân rã tuần tự (sequential) – đơn giản, tổng khớp chính xác:

```
Δ_volume  = (u1 − u0) × cp0
Δ_price   = u1 × (p1 − p0) × (1 − ref)
Δ_cogs    = −u1 × (c1 − c0)
Δ_fees    = −u1 × (f1 − f0)  (+ thay đổi referral)
Δ_ads     = −(ads1 − ads0)          (nếu có dữ liệu QC: CP sau QC)
Σ = CP1 − CP0 (khớp)
```
Giá/COGS/phí kỳ = trung bình có trọng số theo units từ snapshot. SQL function `profit_bridge(t, days)` trả về per‑SKU + tổng; UI waterfall (Recharts BarChart xếp chồng kiểu bậc thang) + bảng top ASIN đóng góp âm/dương với link chi tiết.

Chỉ tính khi cả hai kỳ có ≥ 70% ngày dữ liệu; nếu không hiển thị cảnh báo "chưa đủ dữ liệu".

## 6. Quyết định & đánh đổi
| Quyết định | Lý do | Đánh đổi |
|---|---|---|
| Rule engine bằng **PL/pgSQL** trong Supabase | không thêm hạ tầng, chạy được bằng pg_cron, cùng transaction với dữ liệu, RLS bypass có kiểm soát (SECURITY DEFINER + kiểm tra role khi gọi tay) | logic phức tạp hơn khó test hơn TS; chấp nhận cho ≤ 8 rule |
| Nội suy theo mốc thay vì công thức thống kê | operator hiểu và chỉnh được | không "học" – đúng tinh thần pilot (AI hỗ trợ, người kiểm soát) |
| Ghi đè `stockout_risk_score` bằng inventory component | một nguồn sự thật; số nhập tay cũ là placeholder | mất số cũ (đã có trong `kpi_baseline.snapshot`) |
| Auto‑resolve ngoại lệ khi điều kiện hết | hàng đợi sạch, phản ánh thực tế | phải ghi rõ `auto_resolved` để không tính vào precision |
| Profit bridge tuần tự thay vì Shapley | tổng khớp, dễ giải thích | thứ tự phân rã ảnh hưởng chia nhỏ giữa volume/price – nêu rõ trong chú thích |

## 7. Việc làm
- [x] `007_risk_rules.sql`: cột risk, `risk_history`, `pl_interp`, `compute_risk_score`, `recompute_all_risk`, cột SLA/feedback trên exceptions, `sla_hours`/`cooldown_days`/`rule_toggles` trong policy, `rule_runs`, `run_rules`, `profit_bridge`, views queue/precision, pg_cron 03:30.
- [x] UI Ngoại lệ: hàng đợi SLA, gán, snooze, đóng có feedback, precision theo rule, nút "Chạy rule ngay".
- [x] UI Tổng quan: badge quá hạn, "Vì sao rủi ro" popover trong bảng, lần chạy rule gần nhất.
- [x] Trang Profit bridge `/profit-bridge`.
- [x] Chi tiết ASIN: breakdown risk 4 thành phần + lịch sử risk.
- [x] Chính sách: SLA giờ theo P, cooldown, bật/tắt rule.
