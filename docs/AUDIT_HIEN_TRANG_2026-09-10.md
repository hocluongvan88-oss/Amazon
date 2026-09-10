# AUDIT HIỆN TRẠNG REPOSITORY — Vexim Amazon Managed Operations

Ngày: 2026‑09‑10 · Nhánh: `arena/01a0897b-amazon` (40 commit) · Phương pháp: chỉ đọc code/schema/route/test + `tsc`/`eslint`; **không sửa code, không tạo migration**.
Quy ước trạng thái: **Implemented** (có code + đường đi end‑to‑end, có test hoặc chứng minh được bằng schema/UI) · **Partial** · **Documented only** · **Missing**.
Giới hạn của audit: sandbox không có kết nối tới Supabase/Vercel → không xác minh được trạng thái DB thật, cron đang chạy hay dữ liệu đang có; những điểm đó xếp vào mục 10 (giả định).

---

## 1. Executive summary

**Hệ thống là gì hôm nay:** một control plane nội bộ (Next.js 16 + Supabase Postgres) với 17 màn hình, 18 file migration (~6.000 dòng SQL), 7 file test SQL (~250 assertion), toàn bộ logic nghiệp vụ nằm trong Postgres (function/trigger/RLS), frontend gọi trực tiếp Supabase qua anon key + RLS. **Không có backend/API server riêng, không có route API nào ngoài 2 route auth.**

**Đã build thật (có code + test):**
- RBAC 7 role, permission theo action, tenant‑scoped, delegation có thời hạn, SoD maker ≠ approver (012 + test 33 case).
- Dữ liệu theo ngày `sku_daily_snapshots` (units/revenue/sessions/page_views/ads), metric layer `sku_metrics`, profit bridge, rule engine 7 rule, forecast + inventory plan, reviews/VoC classify + ticket + response policy, tasks + ASIN control room, connector registry + freshness, measurement ledger có baseline/control/concurrent changes, Content Studio (facts → versions → gate → QA → brand approval → publish record → rollback → CVR trước/sau) và A+ theo 17 module Amazon.

**Chưa có / chỉ trên giấy:**
- **Không có kết nối Amazon thật**: không một dòng code nào gọi SP‑API hay Ads API (grep `sellingpartnerapi|advertising-api` chỉ ra trong `docs/GAP_ANALYSIS_AND_ROADMAP.md`). `data_sources.kind='sp_api'` chỉ là bản ghi cấu hình; mọi dữ liệu vào qua **CSV upload từ trình duyệt** (`ImportWizard.tsx`).
- **"Action" hiện là ghi vào DB nội bộ**, không write‑back Amazon: `_connector_internal` (010) cập nhật `amazon_skus.current_price` / `inventory_inbound` trong Postgres và trả `submission_id = gen_random_uuid()`. Dry‑run tạo sẵn payload SP‑API Listings PATCH nhưng không gửi.
- **Không có AI/LLM**: `suggest_response` (009) là template `CASE`; không có key/SDK LLM nào. "Listing Copilot" là Documented only.
- **Thiếu hoàn toàn 4/9 nhóm vận hành hằng ngày**: Returns, Converting Keywords/Search Terms, Promotions/Coupons/Deals, và Traffic ở mức CTR/impressions organic (chỉ có sessions/page_views từ CSV). Ads chỉ ở mức ASIN×ngày (spend/sales/clicks/impressions), không có campaign/keyword.
- **Không có test frontend/E2E**, không observability, README vẫn là template create‑next‑app.

**Kết luận ngắn:** nền tảng governance (RBAC, approval, audit, measurement, content gate) vững hơn mức trung bình của một MVP; nhưng lớp **dữ liệu Amazon thật** và **độ phủ nghiệp vụ hằng ngày** còn mỏng: hệ thống hôm nay là một **"bàn điều khiển đọc CSV + quy trình duyệt"**, chưa phải "vận hành Amazon hằng ngày".

---

## 2. Bảng feature inventory

Chú thích cột: DS = Data source (CSV = CSV import qua UI; DB = tính toán từ dữ liệu đã có; Seed = `002_seed.sql` (5 SKU demo, không tenant); —). Auto = mức tự động hoá thực tế (Rec = chỉ gợi ý/human‑executed; L3 = human approve + hệ thống ghi nhận; L4‑internal = auto có rollback nhưng chỉ ghi DB nội bộ).

| Domain | Feature | Status | Evidence | DS | UI | Backend | Test | Real/Mock | Auto | Risk |
|---|---|---|---|---|---|---|---|---|---|---|
| Arch | Next.js 16 App Router, Supabase SSR auth, proxy bảo vệ route | Implemented | `proxy.ts`, `app/auth/*`, `lib/supabase/*` | — | ✔ | — | ✘ | Real | — | Không có test |
| Arch | API server / route handlers nghiệp vụ | Missing | chỉ `app/auth/callback`, `app/auth/signout` | — | — | ✘ | ✘ | — | — | Mọi logic phụ thuộc RLS + SECURITY DEFINER |
| Arch | Seed/demo data | Partial | `002_seed.sql` (5 SKU, 3 review, recs, exceptions — **không có tenant_id**, viết trước 004) | Seed | — | — | — | Mock | — | Seed cũ có thể không còn chạy được sau 004 |
| Arch | Env/config | Partial | chỉ `NEXT_PUBLIC_SUPABASE_URL/ANON_KEY`, `SUPABASE_INTERNAL_URL`; không `.env.example`; README là template | — | — | — | — | — | — | Onboarding dev khó |
| Auth | 7 role tenant‑scoped | Implemented | `012_permissions.sql:18`, `tenant_members` | DB | Members UI | ✔ | 012 test | Real | — | |
| Auth | Permission theo action (27 key), `has_permission`, `v_role_matrix` | Implemented | `012` §permissions, `my_permissions` | DB | RoleMatrix trong Members | ✔ | ✔ | Real | — | |
| Auth | Delegation có thời hạn ≤ 90 ngày, lý do, revoke, audit | Implemented | `permission_delegations`, `grant_delegation` | DB | ✔ | ✔ | ✔ | Real | — | |
| Auth | SoD (rec, response draft, facts, content) | Implemented | `012:262‑320`, `013:49,218+` | DB | thông báo lỗi | ✔ | ✔ | Real | — | |
| Auth | Scoping theo brand/marketplace | Missing | chỉ `tenant_id`; `amazon_skus.marketplace` là cột dữ liệu, không có scope quyền | — | — | ✘ | ✘ | — | — | 1 tenant = 1 brand mặc định |
| Auth | Audit log | Implemented | `write_audit_log()` trigger trên hầu hết bảng ghi; `/audit` | DB | ✔ | ✔ | gián tiếp | Real | — | Không có tamper‑proof/retention |
| Data | Catalog/COGS/fees/inventory/orders/ads/reviews/sales CSV | Implemented | `lib/import/schemas.ts` (8 kind), `ImportWizard.tsx`, `import_jobs` | CSV | ✔ | ✔ (upsert trực tiếp từ client) | ✘ | Real (tay) | — | Client‑side parse, không validation server |
| Data | Bảng orders chi tiết (order_id, buyer, status) | Missing | orders CSV được **gộp theo ngày×ASIN** vào `sku_daily_snapshots` | — | — | ✘ | — | — | — | Không truy vết đơn |
| Data | Fees chi tiết (FBA/referral/storage theo giao dịch) | Partial | `fee_per_unit`, `referral_fee_pct` trên SKU; `cogs_history` | CSV/manual | ✔ | ✔ | — | Real | — | Không có storage/long‑term fee |
| Data | Returns/refunds | Missing | không có bảng/cột (grep `refund|return_`) | — | ✘ | ✘ | ✘ | — | — | |
| Data | Keywords/search terms | Missing | không có bảng | — | ✘ | ✘ | ✘ | — | — | |
| Data | Promotions/coupons/deals | Missing | không có bảng | — | ✘ | ✘ | ✘ | — | — | |
| Data | SP‑API connector | Documented only | `docs/CONNECTOR_CONTRACT_v0.1.md`; `data_sources.kind='sp_api'` chỉ là registry | — | form đăng ký nguồn | ✘ (không có client/OAuth/job) | ✘ | — | — | **Blocker chính** |
| Data | Ads API connector | Documented only | như trên | — | — | ✘ | ✘ | — | — | |
| Data | Brand Analytics / SQP | Missing | không có | — | ✘ | ✘ | ✘ | — | — | |
| Data | Freshness/SLA/ingestion runs | Implemented | `015`: `data_feeds` (8 feed), `ingestion_runs`, `v_data_freshness`, `FreshnessBanner` | DB | ✔ | ✔ | 015 test | Real | — | Chỉ đo tuổi CSV cuối |
| Data | Reconciliation | Partial | `run_reconciliation` (006) so revenue/units hệ thống vs số nhập tay; `Reconciliation.tsx` | manual | ✔ | ✔ | ✘ | Real | — | Không đối soát với settlement |
| Revenue | Dashboard tổng quan | Implemented | `Dashboard.tsx`, `tenant_daily`, `sku_metrics` | CSV→DB | ✔ | ✔ | ✘ | Real | — | |
| Revenue | Contribution profit / margin baseline | Implemented | `amazon_skus.contribution_profit` (generated), `kpi_baseline`, `sku_metrics.margin_delta_pts` | DB | ✔ | ✔ | 016 | Real | — | |
| Revenue | Profit bridge | Implemented | `profit_bridge()` 007, `ProfitBridge.tsx` | DB | ✔ | ✔ | ✘ | Real | — | |
| Revenue | Ads cost trong margin (TACoS/ACoS) | Implemented | `sku_metrics.tacos_30/acos_30` | CSV ads | ✔ | ✔ | ✘ | Real | — | |
| Revenue | Alerts/recommendations (7 rule) | Implemented | `run_rules` 007/008: MARGIN_EROSION, PRICE_VOLATILITY, VELOCITY_DROP, STOCKOUT_IMMINENT, BELOW_REORDER_POINT, OVERSTOCK, DATA_STALE (+REVIEW_CLUSTER 009) | DB | ✔ | ✔ | gián tiếp | Real | Rec | Chưa có test riêng cho rule |
| Inventory | Available / inbound | Implemented | `inventory_qty`, `inventory_inbound` | CSV | ✔ | ✔ | — | Real | — | |
| Inventory | Reserved / stranded / aged | Missing | không có cột | — | ✘ | ✘ | — | — | — | |
| Inventory | Days of cover, stockout ETA | Implemented | `sku_metrics`, `inventory_plan_sku` | DB | ✔ | ✔ | ✘ | Real | — | |
| Inventory | Forecast + backtest | Implemented | `forecast_sku`, `forecasts`, `forecast_backtests`, `v_forecast_accuracy` (008) | DB | ✔ | ✔ | ✘ | Real | — | Mô hình đơn giản (level+DOW) |
| Inventory | Replenishment recommendation | Implemented | rule BELOW_REORDER_POINT → rec `replenish`, `replenish_rationale` | DB | ✔ | ✔ | ✘ | Real | Rec | |
| Inventory | Purchase order | Partial | action `replenish_po` chỉ **cộng inbound trong DB** (010:106‑109) | DB | ExecutePanel | ✔ | ✘ | Nội bộ | L4‑internal | Không có PO document/supplier flow |
| Returns | Tất cả | Missing | — | — | ✘ | ✘ | ✘ | — | — | |
| Traffic | Sessions/page views/CVR | Implemented | snapshot `sessions`, `page_views`; `cvr_30`, `content_cvr_series` | CSV sales_traffic | ✔ | ✔ | 017 | Real | — | |
| Traffic | Impressions/CTR organic, paid vs organic | Missing | chỉ có ad_impressions/ad_clicks | — | ✘ | ✘ | — | — | — | |
| Keywords | Search term / converting keywords | Missing | — | — | ✘ | ✘ | ✘ | — | — | |
| Promotions | Tất cả | Missing | — | — | ✘ | ✘ | ✘ | — | — | |
| Reviews | Ingestion (CSV), classify topic (từ khoá), triage sao thấp | Implemented | `009`: `review_topics`, `classify_review` (keyword match, không ML), `v_review_triage` | CSV | ✔ | ✔ | ✘ | Real | — | Không có review scraping/API |
| Reviews | VoC ticket, response draft + policy check (cấm xin sửa review) | Implemented | `voc_tickets`, `response_drafts`, `check_response_policy` | DB | ✔ | ✔ | 012 (SoD) | Real | Rec (gửi tay) | |
| Reviews | VoC → task content/qa/ads/inventory/support | Implemented | `create_tasks_from_ticket`, `suggest_tasks_for_ticket` (014) | DB | ✔ | ✔ | 014 test | Real | — | |
| Content | Product facts + evidence + verify (SoD) | Implemented | `product_facts` 013 | manual | ✔ | ✔ | 013 test | Real | — | |
| Content | Versions title/bullets/description/backend/aplus | Implemented | `content_versions` | manual | ✔ | ✔ | ✔ | Real | — | |
| Content | Compliance gate (limits, banned terms, claim→fact) | Implemented | `check_content_compliance` 013/017/018 | DB | ✔ | ✔ | ✔ | Real | — | |
| Content | A+ 17 module Amazon, gate v2, template, preview, handoff .md | Implemented | `018`, `lib/aplus.ts`, `components/AplusEditor.tsx` | DB | ✔ | ✔ | 018 test (40) | Real | — | Handoff thủ công |
| Content | Approval state machine + brand approver + delegation | Implemented | `content_version_guard` 013:218‑300 | DB | ✔ | ✔ | ✔ | Real | L3 | |
| Content | Publish record | Partial | status `published` + `published_by/at`; **không có** URL/screenshot/bằng chứng đã đăng | manual | ✔ | ✔ | ✔ | Real | manual | Publish ≠ đã lên Amazon |
| Content | Diff/rollback | Implemented | `diffLines`, transition `published→rolled_back` | DB | ✔ | ✔ | ✔ | Real | — | |
| Content | Đo CVR trước/sau + measurement ledger | Implemented | `content_impact`, `content_cvr_series`, `measurements` 016 | DB | ✔ | ✔ | 016/017 | Real | — | |
| Content | Listing Copilot (AI draft) | Documented only | `PRODUCT_SCOPE §2.3`; không SDK LLM | — | ✘ | ✘ | ✘ | — | — | |
| Ads | Spend/sales/clicks/impr theo ASIN×ngày | Implemented | snapshot cols, `sku_metrics` | CSV | ✔ | ✔ | — | Real | — | |
| Ads | Campaign/keyword/CPC/bid/budget | Missing | không có bảng | — | ✘ | ✘ | ✘ | — | — | |
| Ads | Ads guardrail theo inventory/content/margin | Partial | chỉ task `ads_guardrail` (014) do người tạo; không có rule tự phát hiện | DB | task | ✔ | 014 | Real | Rec | |
| Ads | Auto‑action ads | Missing | — | — | — | ✘ | — | — | — | |
| Automation | Rule engine + cron | Implemented | `run_rules_all` cron 03:30, snapshots 03:00, forecasts 03:15 (006/007/008) | DB | — | ✔ | — | Real nếu pg_cron bật | — | Không xác minh được cron đang bật |
| Automation | approval_tier ≠ automation_level | Implemented | `recommendations.approval_tier`, `actions.automation_level`, `policy.max_automation_level` (012:231‑247) | DB | ✔ | ✔ | 012 | Real | — | |
| Automation | Action record, idempotency, rate limit, canary, rollback, auto‑rollback | Implemented (nội bộ) | `010`: `idempotency_key` md5, `max_live_actions_per_day`, `canary_asins`, `rollback_action`, `check_auto_rollbacks` | DB | ActionsLog/ExecutePanel | ✔ | ✘ (không test riêng) | **Ghi DB nội bộ, không ghi Amazon** | L4‑internal | Dễ gây hiểu nhầm "đã đổi giá trên Amazon" |
| Automation | Write‑back Amazon thật | Missing | `_connector_internal` 010:87‑110 | — | — | ✘ | — | — | — | |
| Automation | AI/LLM | Missing | — | — | — | ✘ | — | — | — | |
| Testing | SQL tests (7 file) | Implemented | `supabase/tests/012…018` | — | — | — | ✔ | — | — | 001–011 không có test |
| Testing | Unit/integration/E2E frontend | Missing | không jest/vitest/playwright trong `package.json` | — | — | — | ✘ | — | — | |
| Ops | Observability / error tracking | Missing | không Sentry/log pipeline | — | — | — | — | — | — | |

---

## 3. Ma trận 9 nhóm daily Amazon operations

| Nhóm | Dữ liệu có | Nguồn | Chỉ số/UI | Alert/Rec | Đánh giá |
|---|---|---|---|---|---|
| Orders | units, revenue theo ngày×ASIN (gộp) | CSV All Orders | Dashboard, SkuDetail chart, velocity 7/30d | VELOCITY_DROP | **Partial** — không có order‑level, không huỷ/hoàn |
| Inventory | on_hand, inbound, reorder point | CSV FBA inventory | Inventory Planner, DoC, stockout ETA, forecast | STOCKOUT_IMMINENT, BELOW_REORDER_POINT, OVERSTOCK | **Partial** — thiếu reserved/stranded/aged/FC transfer |
| Returns | — | — | — | — | **Missing** |
| Converting keywords | — | — | — | — | **Missing** |
| Traffic | sessions, page_views | CSV Business Report | CVR series | — | **Partial** — không impressions/CTR/organic rank |
| Conversion | CVR 30d, so median, trước/sau content | DB | Content impact, measurement | Listing audit reason "CVR dưới median" | **Partial‑Implemented** — có nhưng phụ thuộc CSV traffic |
| Promotions | — | — | — | — | **Missing** |
| Reviews | rating/title/body | CSV | Triage, topic, ticket, response draft, tasks | REVIEW_CLUSTER | **Implemented** (nghe, không hành động lên Amazon) |
| Advertising | spend, sales, clicks, impressions theo ASIN×ngày | CSV Advertised product | TACoS/ACoS trong metrics & chart | — (không rule ads) | **Partial** — không campaign/keyword/bid |

Trả lời: **chưa thể kiểm tra đủ 9 nhóm mỗi ngày** — 4 nhóm Missing, 4 Partial, 1 Implemented; và tất cả phụ thuộc người upload CSV hằng ngày.

---

## 4. Ma trận Content & Listing Intelligence Studio

| Thành phần | Status | Evidence |
|---|---|---|
| Product Fact Sheet (key/value/unit/source/status) | Implemented | `product_facts` 013; UI tab Facts trong `ContentStudio.tsx` |
| Evidence cho fact (source_type/source_ref bắt buộc khi verify) | Implemented | `product_fact_guard` 013:40‑60 |
| Evidence cho claim trong content (claims[] → fact_id verified) | Implemented | `check_content_compliance` (c) `claim_no_fact` |
| Listing draft/version (title, bullets, description, backend) | Implemented | `content_versions.kind` |
| A+ Content theo module Amazon | Implemented | `aplus_module_specs`, `AplusEditor`, handoff |
| Compliance checker | Implemented | limits, banned terms (global + tenant), claim, stuffing, aplus v2 |
| Approval workflow (draft→qa→brand→approved→published) | Implemented | `content_version_guard` |
| Brand approval / delegation / dừng ở awaiting nếu không có approver | Implemented | 013:272‑305, `v_content_readiness.has_brand_approver` |
| Publish record | Partial | chỉ trạng thái + người/thời điểm; không bằng chứng đã lên Amazon, không sync ngược Listings API |
| Version comparison | Implemented | `diffLines` so với bản published |
| Rollback | Implemented | transition + lý do |
| Performance measurement | Implemented | `content_impact`, `content_cvr_series`, `measurements` (baseline/control/concurrent/confidence) |
| Listing Copilot (AI) | Documented only | không có |
| Keyword/SEO input cho listing | Missing | không có search term data |
| Listing audit (`v_listing_audit`) | Implemented | 013:330‑360 (độ dài, thiếu A+, CVR < median, review tiêu cực) |

---

## 5. Database/schema gap analysis

Có: 40+ bảng/view; RLS bật trên mọi bảng nghiệp vụ; 94 function SECURITY DEFINER trong đó 90 có `SET search_path` (4 không — cần rà: `grep -n "SECURITY DEFINER" supabase/*.sql | grep -v search_path`); pg_cron cho snapshot/rules/forecast.

Thiếu (theo yêu cầu vận hành hằng ngày):
1. `orders` (order‑level: order_id, status, fulfillment, ship date) — hiện chỉ có tổng hợp ngày.
2. `returns` / `refunds` (order_id, asin, qty, reason, refund_amount, disposition).
3. `search_terms` / `keyword_metrics` (campaign, keyword, match type, impressions, clicks, orders, sales theo ngày).
4. `ad_campaigns`, `ad_keywords`, `ad_daily` chi tiết (hiện ads nhét vào `sku_daily_snapshots`).
5. `promotions` (type coupon/deal/promo, start/end, discount, budget, asin list) + liên kết `measurements.concurrent_changes`.
6. `traffic_daily` mở rộng (impressions organic/SQP, CTR, buy box %).
7. `inventory_ledger` (reserved, stranded, aged buckets, FC).
8. `publish_records` (URL/ảnh/thời điểm, sync status) tách khỏi `content_versions`.
9. `job_queue`/`sync_jobs` cho connector (ingestion_runs có nhưng không có worker).
10. Seed `002_seed.sql` không tenant‑aware — nên đánh dấu obsolete.
11. `amazon_skus` gánh quá nhiều vai trò (catalog + rolling metrics + risk) — cần tách dần.

---

## 6. Permission/RBAC gap analysis

Đạt: 7 role; 27 permission action; tenant scope; delegation ≤ 90 ngày có lý do; SoD ở rec/response/facts/content; `approval_tier` tách `automation_level`; `max_automation_level` mặc định L3; live cần `automation_live` + canary + rate limit.

Khoảng trống:
- Không có scope theo **marketplace/brand** trong tenant.
- Quyền `content.publish` không yêu cầu bằng chứng publish.
- Không có **review định kỳ delegation** (báo cáo delegation sắp hết hạn) ngoài bảng.
- `profiles.role (admin/operator/viewer)` từ 001 vẫn tồn tại song song `tenant_members.role` — nguy cơ nhầm lẫn (chỉ còn `has_role` tương thích ngược).
- Chưa có test cho RLS bằng user thật (tests chạy as postgres, bypass RLS — đã ghi trong README tests).
- Không có rate limit/lock‑out ở lớp auth ngoài Supabase mặc định.

---

## 7. Connector / data freshness gap analysis

| Hạng mục | Trạng thái |
|---|---|
| Contract (feed, SLA, settlement lag, report type) | Documented + seeded trong `data_feeds` (8 feed) |
| Registry nguồn (`data_sources`) | Implemented (không lưu secret, `credential_ref`) |
| Ingestion run tracking | Implemented cho CSV (trigger `import_job_to_run`) |
| SP‑API OAuth (LWA), token refresh, seller/marketplace binding | **Missing** |
| Report job (createReport → poll → download → parse) | **Missing** — không có worker/edge function/cron ngoài Postgres |
| Ads API report | **Missing** |
| Backfill/restatement (ads 1/7/28 ngày) | Documented only |
| Validation server‑side khi ingest | Missing (parse ở trình duyệt, upsert trực tiếp) |
| Freshness banner/SLA | Implemented |
| Reconciliation với settlement/finance | Missing (chỉ so số nhập tay) |

---

## 8. Vấn đề nghiêm trọng cần sửa trước pilot

1. **Ngữ nghĩa "Lệnh thực thi" gây hiểu nhầm**: `actions.status='succeeded'`, `submission_id` giả, `mode='live'` — nhưng không có gì lên Amazon. Cần đổi nhãn thành "ghi nhận nội bộ / cần thực hiện tay trên Seller Central" hoặc chặn `live` cho tới khi có connector. Vi phạm nguyên tắc "không gọi human‑executed là automation".
2. **Publish content không có bằng chứng**: `published` không kèm URL/ảnh/người xác nhận trên Amazon → KPI CVR trước/sau có thể đo sai mốc.
3. **Không có kết nối dữ liệu tự động** → freshness phụ thuộc kỷ luật upload CSV; mọi rule/forecast/measurement sai lệch nếu bỏ ngày.
4. **4/9 nhóm vận hành thiếu hoàn toàn** (returns, keywords, promotions, traffic organic) → không thể "vận hành hằng ngày" đúng nghĩa.
5. **Ingest phía client, không validation server**: người có `data.import` có thể upsert bất kỳ giá trị nào vào `sku_daily_snapshots`/`amazon_skus`.
6. **Không có test frontend, không observability**, README template → khó vận hành/khắc phục sự cố.
7. **4 hàm SECURITY DEFINER thiếu `search_path`** — rà và vá (an toàn nhưng cần làm).
8. **`002_seed.sql` lỗi thời** (không tenant) — dễ chạy nhầm ở môi trường mới.
9. Không xác minh được **pg_cron đang bật** trong project thật (nếu không: không có snapshot/rule/forecast hằng ngày).

---

## 9. Đề xuất P0/P1/P2 sau audit

**P0 (trước pilot, không mở rộng write‑action):**
- P0‑A Sửa ngữ nghĩa action: nhãn UI + cột `execution_channel` ('internal_record' | 'manual_seller_central' | 'sp_api') ; khoá `live` khi channel ≠ sp_api.
- P0‑B `publish_records` + bắt buộc bằng chứng (URL/ảnh/thời điểm) khi chuyển `published`.
- P0‑C Connector SP‑API đọc (chỉ đọc) cho 3 report: Orders, FBA inventory, Sales & Traffic — worker ngoài Postgres (Supabase Edge Function/cron hoặc dịch vụ nhỏ), ghi vào `ingestion_runs`.
- P0‑D Schema `orders`, `returns`, `promotions` tối thiểu + CSV import tương ứng (fallback) để đủ 9 nhóm ở mức đọc.
- P0‑E Validation server‑side cho import (RPC `ingest_*` thay upsert trực tiếp).
- P0‑F Vá 4 hàm thiếu `search_path`; đánh dấu 002 obsolete; README + `.env.example`; xác nhận pg_cron.

**P1:**
- Ads API đọc (campaign/keyword/search term) + `ad_*` tables; ads guardrail rule (tồn kho thấp/content chưa duyệt → cảnh báo giảm ngân sách — vẫn Rec).
- Returns analytics ↔ review topic ↔ content task.
- Promotion calendar + margin impact + ghi vào `concurrent_changes` của measurements.
- Test RLS bằng user thật; test cho rule engine 007/008; Playwright smoke cho 5 luồng chính.
- Listing Copilot (AI draft từ facts) sau khi có gate — output luôn vào `draft`.

**P2:** write‑back Amazon có kiểm soát (Listings price, Ads budget) qua canary thật; Brand Analytics/SQP; scope marketplace; observability đầy đủ.

---

## 10. Giả định chưa thể xác minh (sandbox không kết nối Supabase/Vercel)

1. Migration 001→018 đã chạy đủ và đúng thứ tự trên project thật (user xác nhận 018 + test OK; các file trước dựa vào lịch sử phiên).
2. pg_cron đang bật và 3 job (`vexim_daily_snapshots/rules/forecasts`) đang chạy.
3. Có dữ liệu thật của tenant nào chưa, hay chỉ seed/demo.
4. Số user thật, có Brand Approver thật trong tenant khách hay chưa.
5. RLS thực tế đúng với user thường (tests chạy as postgres).
6. Vercel env đúng, không có biến bí mật nào bị lộ.
7. Không có schema drift do chạy tay ngoài repo.

---

## 11. Câu hỏi cho chủ dự án

1. Đã có Seller Central + Developer profile SP‑API (app đăng ký, role Brand Analytics) cho khách pilot chưa? Ai giữ refresh token?
2. Khách pilot có Amazon Ads API access không? Bao nhiêu marketplace?
3. Có quy trình ai upload CSV hằng ngày hiện nay không — hay pilot muốn bắt đầu bằng SP‑API ngay?
4. Returns: nguồn mong muốn là FBA Returns report hay Finances/settlement?
5. Promotions/coupons: khách đang chạy loại nào (coupon, Lightning Deal, Prime Exclusive)? Có cần đọc từ API hay nhập lịch tay đủ?
6. Xác nhận: trong pilot, mọi thay đổi giá/PO đều **thực hiện tay trên Seller Central** và hệ thống chỉ ghi nhận? (Nếu có → P0‑A đổi nhãn ngay.)
7. Bằng chứng publish content chấp nhận dạng nào: URL + ảnh chụp, hay bắt buộc đọc lại qua Listings API?
8. Ai là Brand Approver của tenant pilot; có cần Vexim uỷ quyền tạm không?
9. Có ngân sách cho worker ngoài Postgres (Edge Function / VPS nhỏ) cho connector không?
10. Yêu cầu lưu trữ/kiểm toán (retention audit log, PII trong review/order)?

---

## 12. Cam kết
Nhiệm vụ này **không sửa code, không tạo migration**; chỉ tạo file báo cáo này.

---

## Trả lời câu hỏi cuối

- **Hệ thống có thể vận hành Amazon hằng ngày ở mức nào?** Mức **"giám sát bán tự động dựa trên CSV"**: nếu có người upload orders/inventory/ads/traffic mỗi ngày, hệ thống tính margin, rủi ro, tồn kho, forecast, review triage và đưa gợi ý có phê duyệt. Chưa phải vận hành hằng ngày đúng nghĩa vì thiếu 4 nhóm dữ liệu và không có luồng dữ liệu tự động.
- **Kiểm tra đủ 9 nhóm mỗi ngày chưa?** **Chưa.** 1 Implemented (Reviews), 4 Partial (Orders, Inventory, Traffic/Conversion, Advertising), 4 Missing (Returns, Converting Keywords, Promotions, Traffic organic/CTR).
- **Content/Listing/A+ ở mức nào?** Mức **cao nhất trong repo**: facts → evidence → versions → gate → QA → brand approval → publish → diff/rollback → đo CVR; A+ bám 17 module Amazon, có test. Thiếu: bằng chứng publish, AI copilot, đầu vào keyword.
- **Có kết nối Amazon thật chưa?** **Chưa.** Không có SP‑API/Ads API client, OAuth, hay worker; chỉ registry `data_sources` và hợp đồng trên giấy.
- **Có tự động action thật chưa?** **Chưa.** Khung L3/L4 (idempotency, canary, rate limit, auto‑rollback) đã có nhưng connector là nội bộ — chỉ ghi Postgres. Mọi thay đổi trên Amazon hiện đều là human‑executed.
- **Ba việc ưu tiên đầu tiên:**
  1. Sửa ngữ nghĩa "Lệnh thực thi"/"Publish" cho đúng sự thật (nội bộ/tay) + bằng chứng publish (P0‑A, P0‑B).
  2. Connector SP‑API chỉ đọc cho Orders / Inventory / Sales & Traffic với worker ngoài Postgres (P0‑C).
  3. Bổ sung schema + CSV cho Returns, Promotions, Search terms để đủ 9 nhóm ở mức đọc, kèm validation server‑side (P0‑D, P0‑E).
