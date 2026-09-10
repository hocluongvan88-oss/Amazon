# Operating Governance v0.1 — Vexim Amazon Managed Operations

> Trả lời câu hỏi **ai làm gì, ai duyệt, ai chịu trách nhiệm** trong pilot.
> Product scope (Content/Listing/A+, Ads, Inventory, VoC) nằm ở `PRODUCT_SCOPE_v0.1.md`.

## 1. Bộ máy pilot (≤ 100 SKU, 4–5 người kiêm nhiệm)

| Vai trò tổ chức | Trách nhiệm chính | Role hiện tại trong app | Role mục tiêu (permission‑based) |
|---|---|---|---|
| Owner / Business Lead | Ngân sách, rủi ro, duyệt L2, ký báo cáo pilot, sở hữu Chính sách | owner | owner |
| Ops Lead | Điều phối vận hành; duyệt L1; canary; ads guardrail; được uỷ quyền duyệt content nếu brand cho phép | owner *(tạm)* | ops_lead |
| Marketplace Operator | Import dữ liệu, điều tra exception, đề xuất/thực hiện hành động, tạo listing draft | operator | operator |
| Finance / Cost Owner | Sở hữu COGS, landed cost, phí; đối soát; kiểm tra margin cho L2 | operator *(quy ước)* | finance |
| Content / VoC Operator | Product Facts, listing & A+ draft, review triage, ticket VoC, QA block | operator *(quy ước)* | content_qa |
| Brand Approver | Duyệt cuối content, publish listing/A+ | — *(chưa có)* | brand_approver |
| Viewer | Xem báo cáo | viewer | viewer |

Nguyên tắc bất biến: **maker ≠ approver ≠ verifier**. Không ai tự duyệt thứ mình tạo (đã enforce ở DB cho recommendations; sẽ enforce tương tự cho content).

## 2. Ma trận permission mục tiêu

| Permission | operator | ops_lead | finance | content_qa | brand_approver | owner |
|---|---|---|---|---|---|---|
| Xem dashboard | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Sửa Product Facts | đề xuất | duyệt | – | duyệt | duyệt | ✔ |
| Sửa COGS / phí | – | – | ✔ | – | – | override có lý do |
| Tạo listing / A+ draft | ✔ | ✔ | – | ✔ | ✔ | ✔ |
| Duyệt content QA (compliance) | – | ✔ | – | ✔ | ✔ | ✔ |
| Publish listing / A+ | – | theo uỷ quyền | – | – | ✔ | ✔ |
| Duyệt bid/budget L1 | đề xuất | ✔ | – | – | – | ✔ |
| Duyệt L2 / giá lớn / PO | – | đề xuất | kiểm tra margin | – | nếu là brand owner | ✔ |
| Override policy block | – | – | – | có lý do | có lý do | có lý do |

Triển khai: bảng `permissions(role, action)` + hàm `has_permission(tenant, action)`; RLS/trigger gọi hàm này thay vì so sánh role cứng. Role cũ map: owner→owner, operator→operator, viewer→viewer; thêm 4 role mới không phá dữ liệu.

## 3. Trách nhiệm theo vòng lặp

| Mắt xích | Owner | Việc | KPI |
|---|---|---|---|
| Data | Operator + Finance | Import/connector, xử lý dòng lỗi, COGS effective‑date, đối soát tuần | readiness ≥ 90 %, recon pass ≤ 14 ngày, freshness ≤ 24 h |
| Margin | Finance | Profit Bridge tuần; cảnh báo SKU âm biên | 100 % SKU có COGS có nguồn |
| Decision | Operator | Xử lý khuyến nghị & exception theo SLA (P1 trong ngày, P2 3 ngày) | SLA đạt ≥ 90 %, acceptance rate |
| Risk | Ops Lead | Risk score, canary list, chính sách | 0 hành động ngoài policy |
| Approval | Ops Lead (L1) / Owner (L2) / Brand Approver (content) | Duyệt/từ chối kèm lý do | thời gian duyệt trung vị ≤ 1 ngày |
| Action | Operator | Thực hiện theo checklist/deep link; ghi baseline | 100 % action có baseline |
| Measurement | Ops Lead + Owner | Impact 24 h/72 h/7 ngày, rollback, scorecard | incremental CP, rollback rate |
| Content (mới) | Content/QA → Brand Approver | Facts → draft → compliance → duyệt → publish → đo CVR | xem PRODUCT_SCOPE §KPI |
| VoC (trong vòng lặp) | Content/VoC Operator | Triage → tạo task content/QA/ads/inventory | thời gian đóng ticket, % topic có action |

## 4. Nhịp làm việc

| Tần suất | Việc | Ai |
|---|---|---|
| Hàng ngày | Import/kiểm freshness; exception P1; duyệt tồn đọng | Operator, Ops Lead |
| Hàng tuần | Đối soát; Profit Bridge; review VoC → task; họp L2; content queue | Finance, Ops Lead, Content, Owner |
| 2 tuần | COGS/phí; canary & policy; version compare content | Finance, Ops Lead, Content |
| Tháng | Scorecard, báo cáo pilot, quyết định nâng level tự động hoá | Owner |

## 5. Thang tự động hoá (taxonomy chính thức)

| Level | Mô tả | Trạng thái hệ thống hiện tại |
|---|---|---|
| L0 | Dữ liệu & báo cáo thô | ✔ |
| L1 | Rule/AI phát hiện & cảnh báo | ✔ (rule engine, exception queue) |
| L2 | Recommendation có evidence | ✔ một phần (có expected_impact, chưa có evidence panel) |
| L3 | Human approve, hệ thống chuẩn bị action/deep link/checklist | ◐ (approve có; action vẫn thủ công, chưa deep link) |
| L4 | Bounded auto‑action có giới hạn + rollback | ◐ khung `execute_recommendation`/`rollback_action`/canary có, **chưa có write‑back** thật |
| L5 | Tự động hoá nhạy cảm | không làm trong MVP |

**Gọi đúng tên:** pilot hiện tại là *decision support / human‑executed*. Không báo cáo là "tự động hoá" khi chưa có write‑back.

> Lưu ý: DB hiện dùng `required_approval_level ∈ {L0,L1,L2}` (cấp duyệt), khác với thang L0–L5 (mức tự động hoá). Sẽ đổi tên cột thành `approval_tier` để tránh nhầm.
