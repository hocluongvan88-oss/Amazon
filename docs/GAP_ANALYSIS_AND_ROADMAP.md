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

### Tuần 3‑4 – Canonical model & daily snapshot ✅ (hoàn thành 2026‑09‑10, thiết kế: `docs/WEEK3-4_DESIGN.md`)
- [x] `sku_daily_snapshots` (grain SKU×ngày, state + flow, NULL ≠ 0), chụp state hằng ngày qua `capture_daily_snapshots` + pg_cron, nút chụp tay.
- [x] Ingestion pilot **không cần SP‑API**: import All Orders (gộp ngày×ASIN, bỏ Cancelled, ghi 0 cho ASIN không bán) và Sponsored Products daily; `refresh_sku_rolling_from_snapshots` đồng bộ 30 ngày về SKU khi đủ ≥20 ngày. SP‑API để giai đoạn systemize.
- [x] Metric layer `sku_metrics()`: velocity 7/30 & Δ%, coverage, price volatility, CP/biên & margin Δ vs baseline, DoC/ETA hết hàng, inventory health theo lead time + safety stock, TACoS/ACoS/CVR, aging. `tenant_daily()` cho biểu đồ brand.
- [x] UI: biểu đồ xu hướng 30/90 ngày trên Tổng quan; cột Bán/ngày 7d & ETA; thẻ **Kết nối dữ liệu & gate 3‑4**; trang **Chi tiết ASIN** (`/skus/[id]`: 6 tile, 4 biểu đồ, tab gợi ý/ngoại lệ/review/COGS/snapshot, modal sửa – COGS mới đi vào lịch sử).
- [x] **Gate**: đối soát với Seller Central (`run_reconciliation`, lệch ≤ tolerance), coverage ≥90% doanh thu có ≥20 ngày, snapshot ≤2 ngày.

### Tuần 5‑6 – Profit bridge & exception queue ✅ (007)
- [x] Hàm `compute_risk_score(sku_id)` = tổ hợp có trọng số (inventory / margin Δ / velocity / volatility), trọng số từ `policy_register`; ghi `risk_components` (lý do từng thành phần, độ tin cậy) + `risk_history`.
- [x] Trigger gán `required_approval_level`/`status` (đã có từ 005) – gợi ý do rule sinh ra đi qua cùng luồng.
- [x] Rule engine `run_rules()` (pg_cron 03:30 UTC + nút chạy tay): STOCKOUT_IMMINENT, BELOW_REORDER_POINT, OVERSTOCK, MARGIN_EROSION, VELOCITY_DROP, NO_SALES_7D, PRICE_VOLATILITY, DATA_STALE → `exceptions` (dedupe, cooldown sau cảnh báo sai, tự đóng khi hết điều kiện) + `recommendations` kèm `rationale` giải thích được.
- [x] Trang **Profit bridge** `/profit-bridge`: phân rã Δ CP theo sản lượng / giá / COGS / phí / ads, 7‑14‑28 ngày, waterfall + theo ASIN.
- [x] Ngoại lệ: gán người xử lý, SLA theo P‑level (`sla_hours`), snooze, đếm quá hạn trên Tổng quan.
- [x] **Gate check**: bảng precision theo rule (operator đánh dấu đúng/sai khi đóng) trên trang Ngoại lệ.
- [ ] Chưa có (cần dữ liệu Amazon API): mất Featured Offer, ACoS vượt ngưỡng theo campaign, sụt CVR (chỉ có khi nhập sessions).

### Tuần 7‑8 – Inventory & replenishment ✅ (008)
- [x] Forecast baseline: 3 mô hình (naive7 / ma28 / SES + hệ số thứ trong tuần), backtest cửa sổ 7 ngày trên 90 ngày, tự chọn MAPE thấp nhất cho từng ASIN; lưu `forecasts(sku_id, made_on, date, horizon, p50, p90, model)` + `forecast_backtests`. pg_cron 03:15 UTC.
- [x] Gợi ý `replenish` tự sinh: qty = nhu cầu dự báo (lead time + an toàn + chu kỳ 28 ngày) − (on hand + inbound); rule STOCKOUT_IMMINENT dùng cùng công thức, rationale nêu mô hình + MAPE.
- [x] Trang **Tồn kho** `/inventory`: trạng thái (hết / đặt ngay / đặt sớm / tồn dư / ổn), DoC, ngày hết hàng, ngày phải đặt, đề xuất, forecast vs actual (P50/P90), **scenario planner** (lead time, an toàn, P90, tính inbound) so với mặc định, tạo gợi ý 1 click.
- [x] Inbound: cột `inventory_inbound` (import Tồn kho / sửa ASIN), có trong snapshot.
- [x] **Gate check**: MAPE mô hình chọn vs naive trên trang Tồn kho (`v_forecast_accuracy`).
- [ ] Chưa có: đối soát inbound với shipment thực tế (cần dữ liệu FBA shipment).

### Tuần 9‑10 – Review / VOC ✅ (009)
- [x] Bảng `review_topics` (13 chủ đề mặc định, từ khoá EN/VI, chỉnh được), `review_classifications(review_id, topic, sentiment, severity, confidence, matched[])`, `voc_tickets(type: defect|content|logistics|service|other, priority, status)`, `response_drafts`.
- [x] Phân loại theo từ khoá (giải thích được, không gọi LLM) – trigger khi thêm review + `classify_reviews()`; chỉ **listening/triage**. Rule `REVIEW_CLUSTER` (≥3 review ≤3★ cùng chủ đề/30 ngày) → ngoại lệ P2.
- [x] Trang **Review/VOC** `/reviews`: triage sao thấp, cụm chủ đề (30/90 ngày, theo ASIN), ticket VOC (gán, trạng thái, ghi chú), nháp phản hồi theo mẫu + **policy check** (danh sách từ cấm trong `policy_register.prohibited_phrases`, link/SĐT/email) + duyệt bởi người khác + đánh dấu đã gửi thủ công.
- [x] Import CSV loại **Review khách hàng** (+ template).
- [x] **Gate check**: tab QA – rút mẫu ngẫu nhiên, precision phân loại theo chủ đề; trigger DB chặn duyệt/gửi nếu có từ ngữ bị cấm (0 prohibited wording).
- [ ] Nâng cấp phân loại bằng LLM khi có ngân sách API (giữ nguyên schema, `method='llm'`).

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
