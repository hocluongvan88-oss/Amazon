# Vexim Ops – Đánh giá khoảng cách & kế hoạch bổ sung

_Cập nhật: 2026‑09‑10 · Đối chiếu code hiện tại với khung 7‑mắt xích, RBAC/multi‑tenant, roadmap MVP 14 tuần._

---

## 1. Hiện trạng theo 7 mắt xích

| # | Mắt xích | Có gì trong code | Mức độ | Thiếu gì |
|---|---|---|---|---|
| 1 | **Data** | Bảng `amazon_skus`, `raw_reviews`; nhập tay qua form | 🟠 20% | Không có ingestion SP‑API/Ads/CSV, không có snapshot theo ngày, không có bảng fees/ads/orders/inbound, không có data contract/tolerance check |
| 2 | **Margin / Metric layer** | `contribution_profit` (generated column), view `v_sku_overview` (DoC, LN 30 ngày) | 🟠 30% | Không có lịch sử theo ngày → không tính được margin Δ, velocity, volatility, TACoS/ACoS/CVR; không có baseline KPI |
| 3 | **Decision (Detect → Diagnose)** | Không có. `recommendations` chỉ là seed tay | 🔴 0% | Không có rule engine/job sinh gợi ý; không có forecast; không có review clustering |
| 4 | **Risk** | Cột `risk_score`, `required_approval_level` trong bảng | 🔴 5% | Không có hàm tính risk tổng hợp (margin Δ + inventory health + velocity + volatility); cấp duyệt gán tay; chưa có trigger `assign_recommendation_status()` |
| 5 | **Approval (Human‑in‑the‑loop)** | UI đổi trạng thái đầy đủ; RLS theo role đã viết | 🟡 40% | **Chưa có đăng nhập** → ai có link cũng duyệt; không ghi `approved_by`; không kiểm tra cấp duyệt L1/L2 theo role; không ghi `audit_log`; không có lý do từ chối/ghi chú |
| 6 | **Amazon Action (Execute)** | Nút "Đánh dấu đã thực thi" (thủ công) | 🔴 0% | Không có dry‑run, canary, idempotency key, rate limit, rollback thật; không có adapter SP‑API write |
| 7 | **Measurement** | Không có | 🔴 0% | Không đo trước/sau, không có incremental contribution, không có KPI tuần/cohort, không có báo cáo pilot |

**Xuyên suốt**

| Yếu tố | Hiện trạng |
|---|---|
| RBAC | Schema có `profiles.role` + RLS + `current_role_in()`; **chưa bật Auth**, chế độ pilot mở cho `anon` |
| Multi‑tenant | ❌ Không có `tenant_id`/`brand_id` ở bất kỳ bảng nào → không tách được 1‑3 brand pilot |
| Marketplace | Cột `marketplace` chỉ trên `amazon_skus`, hardcode `'US'` |
| Audit log | Bảng có, **không ai ghi** |
| Policy guardrails | Không có bảng policy/ngưỡng; ngưỡng P0‑P3 chỉ là nhãn |
| Cấp tự động hóa L0‑L4 | Chỉ nhãn `L0/L1/L2` trên gợi ý, không có nghĩa vận hành |

> **Kết luận:** hệ thống hiện là **cockpit hiển thị + workflow duyệt tay** trên dữ liệu nhập tay. Mắt xích 1‑2 mới có khung, 3‑4‑6‑7 chưa tồn tại. Điều này phù hợp với tuần 1‑4 của roadmap, chưa vào tuần 5.

---

## 2. Khoảng cách giao diện (UI)

| Màn hình cần có | Hiện có | Thiếu |
|---|---|---|
| Đăng nhập / chọn tenant | ❌ | Login (magic link / email), chọn brand, hiển thị role hiện tại |
| Tổng quan | ✅ | Bộ chọn khoảng thời gian, so sánh kỳ trước (Δ), biểu đồ xu hướng LN/tồn kho 30‑90 ngày, chuyển brand |
| Chi tiết ASIN | ❌ | Lịch sử giá/tồn kho/doanh số, profit bridge của ASIN, review của ASIN, gợi ý & ngoại lệ liên quan, ghi chú |
| Profit bridge | ❌ | Phân rã Δ LN tuần này vs tuần trước theo: giá, volume, fees, ads, COGS |
| Gợi ý & phê duyệt | ✅ | Lý do từ chối bắt buộc, hiển thị ai duyệt/khi nào, chặn nút nếu role không đủ cấp, xem diff (before/after) + dự báo tác động, checklist policy trước khi duyệt |
| Ngoại lệ | ✅ | Gán người xử lý, SLA theo P‑level, comment thread |
| Tồn kho / Replenishment | ❌ | Bảng DoC, forecast vs actual, đề xuất PO, inbound reconciliation, scenario planner |
| Review / VOC | ❌ | Phân cụm chủ đề, triage sao thấp, ticket defect/content, workflow bản nháp phản hồi (chỉ triage, không can thiệp rating) |
| Nhật ký (Audit) | ❌ | Timeline mọi hành động, filter theo user/ASIN/loại |
| Đo lường / Báo cáo pilot | ❌ | Incremental contribution, inventory impact, VOC resolution, operator time, automation rate, compliance incidents |
| Cài đặt | ❌ | Policy/ngưỡng risk, cấp duyệt theo loại action, quản lý thành viên & role, data connection status |
| Nhập dữ liệu | Form 1 SKU | Import CSV (Seller Central export), trạng thái kết nối SP‑API, lần đồng bộ cuối, lỗi đối soát |

---

## 3. Kế hoạch bổ sung (map theo roadmap 14 tuần)

### Sprint 0 – Dọn nền ✅ (hoàn thành 2026‑09‑10)
- [x] Xoá thư mục `web/` trùng lặp; một codebase duy nhất.
- [x] Bật **Supabase Auth** (magic link + mật khẩu), trang `/login`, `proxy.ts` bảo vệ route, user/role/brand ở sidebar.
- [x] Gỡ policy `anon` (gộp vào `004`).
- [x] Migration `004_tenancy_auth.sql`: `tenants`, `tenant_members(tenant_id,user_id,role)`; `tenant_id` mọi bảng; RLS theo tenant; bộ chọn brand trên UI.
- [x] `audit_log` tự ghi qua trigger trên `recommendations`, `exceptions`, `amazon_skus` (ai, hành động, before/after, diff). Trang **Nhật ký**.
- [x] Trigger `guard_recommendation_transition`: kiểm tra chuyển trạng thái hợp lệ, cấp duyệt theo role (L0/L1 → operator+, L2 → owner), bắt buộc lý do từ chối/hoàn tác, tự ghi `submitted_by/approved_by/rejected_by/executed_by`. UI khoá nút + modal lý do + timeline.
- [x] Trang **Thành viên** (owner): thêm theo email, đổi role, gỡ; chặn gỡ owner cuối.

### Tuần 1‑2 – Discovery & Data contract ✅ (hoàn thành 2026‑09‑10)
- [x] Migration `005_data_contract.sql`: `policy_register` (1 dòng/brand, tự tạo), `cogs_history` (đồng bộ vào SKU), `kpi_baseline`, `import_jobs`; cột `lead_time_days`, `supplier`, `revenue_last_30d`, `sessions_last_30d`, `cogs_source/fee_source`, `status` trên SKU.
- [x] Trigger `assign_recommendation_level`: cấp duyệt từ risk score + % đổi giá theo policy; chặn đổi giá vượt `price_change_max_pct`; review_response tối thiểu L1.
- [x] Trang **Chính sách** (`/settings/policy`, owner sửa, người khác xem): ngưỡng L0/L1/L2, giới hạn đổi giá, biên tối thiểu, P0–P2, trọng số risk, lead time/safety stock, gate %, tolerance. Validate ràng buộc, ghi audit.
- [x] Trang **Nhập dữ liệu** (`/import`): 5 loại (danh mục, COGS, doanh số 30 ngày, tồn kho FBA, phí), tự khớp cột theo header Seller Central, preview + validate từng dòng, upsert theo lô, lịch sử import kèm lỗi. File mẫu tại `/templates/*.csv`.
- [x] **Gate check** trên Tổng quan: % doanh thu có đủ COGS + FBA fee + referral, thanh tiến độ vs mục tiêu, liệt kê trường thiếu; nút **Chốt baseline KPI** (RPC) làm mốc đo incremental.

### Tuần 3‑4 – Canonical model & daily snapshot
- [ ] Bảng `sku_daily_snapshots(tenant_id, sku_id, date, price, units, revenue, fees, ad_spend, sessions, cvr, inventory_fba, inventory_inbound, …)`.
- [ ] Bảng `orders_daily`, `ad_daily`, `fees_daily`, `inbound_shipments`.
- [ ] Job ingestion (Supabase Edge Function/cron hoặc worker riêng): SP‑API Reports (Sales & Traffic, FBA Inventory, Fee Preview), Ads API. Lưu raw → chuẩn hoá → snapshot.
- [ ] Metric layer (SQL views/materialized): CP, margin %, TACoS, ACoS, CVR, DoC, velocity 7/30 ngày, price volatility, margin Δ vs baseline, aging.
- [ ] UI: biểu đồ xu hướng trên Tổng quan + trang **Chi tiết ASIN**; trạng thái kết nối & lần sync cuối.
- [ ] **Gate check**: báo cáo đối soát doanh thu/phí vs Seller Central, tolerance cấu hình được.

### Tuần 5‑6 – Profit bridge & exception queue
- [ ] Hàm `compute_risk_score(sku_id)` = tổ hợp có trọng số của margin Δ, inventory health (DoC vs lead time), velocity change, price volatility. Trọng số trong `policy_register`.
- [ ] Trigger `assign_recommendation_status()`: từ `risk_score` + action type → `required_approval_level` + `status` ban đầu (L0 auto‑approve trong ngưỡng, L1/L2 → pending).
- [ ] Rule engine detect (job hằng ngày): sụt traffic/CVR, mất Featured Offer, ACoS vượt ngưỡng, margin Δ âm, tồn dưới ROP → sinh `exceptions` + `recommendations` kèm `rationale` giải thích được.
- [ ] Trang **Profit bridge**: phân rã Δ CP theo giá/volume/fees/ads/COGS, tuần vs tuần.
- [ ] Ngoại lệ: gán người xử lý, SLA theo P‑level, đếm quá hạn.
- [ ] **Gate check**: bảng precision cảnh báo (operator đánh dấu đúng/sai) hiển thị trong Đo lường.

### Tuần 7‑8 – Inventory & replenishment
- [ ] Forecast baseline (moving average / Holt‑Winters) lưu vào `forecasts(sku_id, date, horizon, p50, p90, model)`; backtest vs naive.
- [ ] Gợi ý `replenish` tự sinh: qty đề xuất từ forecast × lead time + safety stock − on hand − inbound.
- [ ] Trang **Tồn kho**: DoC, stockout/overstock, forecast vs actual, inbound reconciliation, scenario planner (đổi lead time/safety stock → xem kết quả).
- [ ] **Gate check**: MAPE forecast vs naive trên trang Đo lường.

### Tuần 9‑10 – Review / VOC
- [ ] Bảng `review_topics`, `review_classifications(review_id, topic, sentiment, severity)`, `voc_tickets(type: defect|content|logistics, status)`.
- [ ] Job phân loại (LLM có policy prompt + danh sách từ cấm) → chỉ **listening/triage**, tuyệt đối không tạo action tác động rating.
- [ ] Trang **Review/VOC**: cụm chủ đề theo ASIN, triage sao thấp, tạo ticket, bản nháp phản hồi có policy check + duyệt người.
- [ ] **Gate check**: QA mẫu ngẫu nhiên, precision phân loại, 0 prohibited wording.

### Tuần 11 – Bounded automation
- [ ] Bảng `actions(recommendation_id, idempotency_key, mode: dry_run|canary|live, payload, response, status)`, `rollbacks`.
- [ ] Adapter SP‑API write (Listings Items API đổi giá) với: dry‑run mặc định, canary theo danh sách ASIN nhỏ, rate limit, retry idempotent, rollback tự động về giá cũ khi metric xấu trong N giờ.
- [ ] UI: nút "Chạy thử (dry‑run)" hiển thị payload; "Thực thi" chỉ enable sau dry‑run OK + đúng role; lịch sử action & rollback.
- [ ] **Gate check**: 0 policy incident, 0 uncontrolled write (đếm từ `actions` không có `recommendation_id` đã approved).

### Tuần 12‑14 – Đo lường & quyết định
- [ ] Bảng `experiments`/đánh dấu trước‑sau cho từng action; tính incremental CP với khoảng tin cậy (so với cohort ASIN không tác động).
- [ ] Trang **Đo lường**: incremental contribution, inventory impact, VOC resolution rate, operator time saved, automation rate (% action L0 tự chạy), compliance incidents, backlog.
- [ ] Xuất **báo cáo pilot** (PDF/Markdown) với 4 bằng chứng: dữ liệu đối soát, operator dùng workflow, action tạo impact, 0 incident.

---

## 4. Thứ tự ưu tiên đề xuất

1. **Sprint 0** (Auth, tenant, audit, lock‑down) – điều kiện tiên quyết để có thể cho khách pilot dùng.
2. **Daily snapshot + import CSV** – không có lịch sử thì không tính được risk, không có gì để đo.
3. **Risk score + rule engine detect** – biến hệ thống từ "hiển thị" thành "đề xuất".
4. Inventory forecast → VOC → Bounded automation → Measurement theo đúng roadmap.

## 5. Nguyên tắc giữ nguyên khi xây
- Human‑override ở mọi cấp; L0 chỉ cho action có ngưỡng nhỏ, có rollback.
- Không scraping làm nguồn chính; SP‑API / Ads API / Seller Central exports.
- Review chỉ listening/triage.
- Mọi đề xuất phải có `rationale` operator đọc hiểu được và `audit_log` đầy đủ.
- Không claim "AI tự trị"; báo cáo bằng dữ liệu đối soát và khoảng tin cậy.
