# Product Scope & Workflow v0.1 — Vexim Amazon Operations Control Plane

> Bổ sung cho `OPERATING_GOVERNANCE_v0.1.md`. Nguồn: phân tích nội bộ ngày 10/9/2026.
> North Star: **incremental contribution profit**, hỗ trợ bởi CVR, in‑stock rate, wasted ad spend, review issue resolution.

## 0. Hiện trạng thẳng thắn (đối chiếu với repo)

| Phân hệ | Đã có | Thiếu |
|---|---|---|
| Data | CSV import 8 loại, validation, import_jobs, reconciliation, readiness | Connector abstraction, freshness monitor, SP‑API/Ads API |
| Margin | cogs_history, profit_bridge (giá/phí/ads/COGS), tenant_daily | storage fee, returns/refunds, coupons, reimbursements, stockout cost |
| Decision/Risk | rule engine, exceptions, risk_history, canary, policy_register | evidence panel per recommendation |
| Approval | approve/reject có lý do, tier L0–L2, maker≠approver | permission theo hành động, content approval riêng |
| Action | actions, rollbacks, execute_recommendation, check_auto_rollbacks | deep link/checklist, baseline snapshot 24h/72h/7d chuẩn hoá |
| Measurement | action_impact CI, pilot_scorecard, evidence gates | KPI content/ads/AI quality |
| Reviews/VoC | raw_reviews, topics, classification, tickets, response_drafts + policy check | liên kết ticket → task content/QA/ads/inventory |
| **Content & Listing** | **không có gì** | toàn bộ Studio (§2) |
| Ads | ad_spend/ad_sales theo ngày trong snapshot | campaign‑level data, guardrail, bid/budget recommendation |

## 1. Kiến trúc mục tiêu

```
              Portfolio / ASIN Control Room
      ┌──────────────┼──────────────┐
 Revenue & Ads   Content & Listing   Inventory
      └──────────────┼──────────────┘
           Reviews & Voice of Customer
                     ▼
        Diagnosis + Evidence + Impact
                     ▼
                Action Queue  (một hàng đợi duy nhất: price/ads/inventory/content/voc)
      ┌──────────────┼──────────────┐
 Human approve   Policy/QA gate   Auto‑action L4 (bounded)
      └──────────────┼──────────────┘
          Amazon action / manual task (deep link + checklist)
                     ▼
            Measurement + rollback (24h / 72h / 7d)
```

Data: `Source connector (CSV | SP‑API | Ads API) → normalized model → metrics → rules/AI → action queue`. CSV là **bootstrap/fallback**, không phải kiến trúc cuối; logic nghiệp vụ không được viết trực tiếp trên file.

## 2. Content & Listing Intelligence Studio (P0)

Workflow: **Product Facts → Analysis → Opportunity → Draft (Listing Copilot / A+ Builder) → Compliance Gate → Operator Review → Brand Approval → Publish → Measure CVR/CTR**.

### 2.1 Product Fact Sheet
- `product_facts(sku_id, key, value, unit, source_type, source_ref, verified_by, verified_at, status)`.
- Mọi claim trong content phải trỏ về ≥ 1 fact đã verified; AI chỉ được viết từ facts + reviews + keywords, không bịa.
- Sửa fact: operator đề xuất → content_qa/ops_lead duyệt.

### 2.2 Listing audit & Content Opportunity queue
- Audit theo ASIN: độ dài title/bullets, thiếu backend terms, ảnh < 6, không có A+, CVR dưới median danh mục, review topic tiêu cực chưa được giải thích trong listing.
- Mỗi opportunity là 1 item trong Action Queue (type=`content`) có evidence.

### 2.3 Listing Copilot & A+ Builder
- `content_versions(sku_id, kind ∈ title|bullets|description|backend|aplus, version, body jsonb, brief, created_by, status ∈ draft|qa_passed|approved|published|rolled_back, parent_version)`.
- A+ dạng template module (Standard Image & Text, Comparison Chart, Four Image & Text…) — chưa cần editor kéo thả.
- Image brief / creative brief là output text kèm version.

### 2.4 Compliance Gate
- Kiểm tra tự động: claim không có fact (block), từ cấm/health claim (block), độ dài & ký tự Amazon (block), nhất quán giữa title/bullets/A+ (warn), keyword stuffing (warn).
- content_qa/brand_approver có thể override **kèm lý do**, ghi audit.

### 2.5 Approval & Publish
- Content approval tách khỏi action approval: draft → QA pass → Brand Approver duyệt → publish (thủ công qua checklist ở pilot; API write‑back ở P2).
- Preview desktop/mobile; version compare (diff) và rollback về version trước.

### 2.6 Measurement
- Baseline CVR/CTR/sessions 14 ngày trước publish vs 14 ngày sau (dùng `action_impact` mở rộng cho action type=content).

## 3. Reviews/VoC trong vòng lặp (P0)
- Mỗi `voc_ticket` có thể sinh task: `content` (giải thích/hướng dẫn), `qa_product` (kiểm batch), `ads_guardrail` (giảm traffic vào variation lỗi), `support`, `inventory_investigation`.
- Hiển thị trong ASIN Control Room cùng margin/ads/inventory; không còn là tab "ngoài vòng lặp".

## 4. Ads guardrail (P1)
- Dữ liệu campaign/ad group/target theo ngày (CSV Sponsored Products bulk → sau là Ads API).
- Rule: ASIN hết hàng/ sắp hết → đề xuất pause; content health thấp → không tăng budget; ACoS > break‑even ACoS (từ margin) → đề xuất giảm bid.
- L4 chỉ cho: pause ads khi out‑of‑stock, bid ±10 % trong ngưỡng chính sách, có rollback.

## 5. Action record chuẩn (áp dụng mọi loại action)
baseline_snapshot · change (before/after) · approver · evidence · expected_kpi · actual_kpi_24h/72h/7d · rollback_condition · rollback_result.

## 6. KPI bổ sung

**Content:** time diagnosis→draft; first‑pass acceptance; % claim bị QA chặn; % publish có đủ evidence; approval time; ΔCVR, ΔCTR trước/sau; return rate do expectation mismatch; content rollback rate.
**Ads:** CP sau ads; wasted spend; incremental sales; % action có post‑measurement; override rate; stockout hours tránh được.
**AI quality:** acceptance rate; override rate; FP/FN; policy‑block precision; rollback rate; % quyết định có evidence; % tác vụ lặp được tự động; chi phí/action.

## 7. Backlog

### P0 (trước khi mở rộng pilot)
1. Permission theo hành động (`permissions`, `has_permission`, 4 role mới) — thay thế so sánh role cứng.
2. Đổi tên `required_approval_level` → `approval_tier`; định nghĩa L0–L5 trong app & docs.
3. Data connector abstraction: `data_sources`, `ingestion_runs`, freshness monitor; CSV là 1 connector.
4. Product Fact Sheet + evidence.
5. Listing draft & A+ draft (content_versions) + Compliance Gate + content approval flow.
6. VoC ticket → task (5 loại) và ASIN Control Room gộp view.
7. KPI content/AI quality vào scorecard.

### P1 (trong pilot 90 ngày)
Listing Copilot (AI draft từ facts) · A+ template builder · version compare & rollback · before/after CVR view · evidence panel cho recommendation · deep link/checklist · ads guardrail liên kết inventory & content health · review topic → content/QA task.

### P2 (sau khi chứng minh hiệu quả)
SP‑API/Ads API write‑back giới hạn · bounded auto bid/budget · image brief & asset generation có duyệt · experiment framework · multi‑marketplace localization · auto publish theo permission + policy gate.

## 8. Quyết định cần chốt

| # | Câu hỏi | Đề xuất |
|---|---|---|
| 1 | MVP có listing & A+? | Có |
| 2 | Ai duyệt cuối content? | Brand Approver (hoặc Ops Lead được uỷ quyền); QA có quyền block |
| 3 | CSV hay API? | CSV bootstrap; connector/API là kiến trúc chính |
| 4 | Mức tự động hoá thật? | L1–L3 mặc định; L4 chỉ cho action reversible rủi ro thấp |
| 5 | North Star? | Incremental contribution profit + CVR, in‑stock, wasted spend, review resolution |
