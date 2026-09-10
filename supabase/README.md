# Supabase — thứ tự chạy SQL

Vào **Supabase Dashboard → SQL Editor → New query**, dán từng file và bấm **Run**:

| Thứ tự | File | Nội dung | Khi nào |
|---|---|---|---|
| 1 | `001_schema.sql` | Bảng, index, trigger, RLS cơ bản, view | Bắt buộc |
| 2 | `002_seed.sql` | **LỖI THỜI** (không tenant, tự dừng khi chạy). Dùng `002b_seed_tenant.sql` (seed demo theo tenant slug, idempotent) | Tuỳ chọn |
| 3 | `004_tenancy_auth.sql` | **Sprint 0**: tenants, `tenant_id` mọi bảng, RLS theo tenant, guard chuyển trạng thái theo cấp duyệt, audit trigger, gỡ quyền `anon` | Bắt buộc trước khi cho người dùng thật vào |
| 5 | `006_snapshots_metrics.sql` | **Tuần 3‑4**: `sku_daily_snapshots` (grain SKU×ngày), `capture_daily_snapshots` + lịch pg_cron 03:00 UTC, `sku_metrics()` & `tenant_daily()` (metric layer), `refresh_sku_rolling_from_snapshots`, `reconciliation_checks` + `run_reconciliation`, view `v_data_connections` | Bắt buộc |
| 6 | `007_risk_rules.sql` | **Tuần 5‑6**: `risk_score`/`risk_components`/`risk_history`, `compute_risk_score`, rule engine `run_rules` (8 rule, dedupe/cooldown/auto‑resolve, pg_cron 03:30 UTC), SLA ngoại lệ (`due_at`, `assigned_to`, `snoozed_until`, feedback), `rule_runs`, views `v_exception_queue`/`v_rule_precision`, `profit_bridge()` | Bắt buộc |
| 7 | `008_forecast_inventory.sql` | **Tuần 7‑8**: `inventory_inbound`, `forecasts`/`forecast_backtests`, `forecast_sku`/`run_forecasts` (pg_cron 03:15 UTC), `inventory_plan(t, lead_time, safety, p90, inbound)` cho trang Tồn kho & scenario, `replenish_rationale`, `run_rules` bản mới dùng forecast, view `v_forecast_accuracy` | Bắt buộc |
| 8 | `009_reviews_voc.sql` | **Tuần 9‑10**: `review_topics` (seed 13 chủ đề), `review_classifications` + `classify_review(s)` (trigger khi insert review), `voc_tickets`, `response_drafts` + `check_response_policy` + guard duyệt (người duyệt ≠ người soạn, chặn từ cấm), `suggest_response`, views `v_review_triage`/`v_review_topic_summary`/`v_classification_precision`, rule `REVIEW_CLUSTER`, policy `prohibited_phrases` | Bắt buộc |
| 9 | `010_actions.sql` | **Tuần 11**: `actions` + `rollbacks` (idempotency, dry_run/canary/live, guard chặn ghi trực tiếp), `execute_recommendation(rec, mode)`, `rollback_action`, `check_auto_rollbacks` (cron 03:30), view `v_automation_stats`, policy `automation_live`/`canary_asins`/`rollback_watch_hours`/`rollback_units_drop_pct`/`max_live_actions_per_day` | Bắt buộc |
| 13 | `014_tasks_control_room.sql` | **P0‑4**: `tasks` (content / qa_product / ads_guardrail / support / inventory_investigation / content_opportunity; đóng phải có outcome), `suggest_tasks_for_ticket` + `create_tasks_from_ticket` (VoC → hành động), `create_content_opportunity_tasks` (từ listing audit), `asin_control_room` (JSON gộp margin/ads/tồn kho/content/VoC/queue + tín hiệu chéo) | Bắt buộc |
| 12 | `013_content_studio.sql` | **P0‑2/3**: `product_facts` (evidence, SoD, immutable khi verified), `content_versions` (title/bullets/description/backend/A+; version tự tăng; state machine draft→QA→brand→publish; publish = ghi nhận thủ công), `content_banned_terms`, `check_content_compliance` (Compliance Gate), `v_listing_audit` (điểm cơ hội), `v_content_readiness`, `content_impact` (CVR trước/sau + thay đổi đồng thời + confidence) | Bắt buộc |
| 11 | `012_permissions.sql` | **P0‑1**: 7 role tenant‑scoped, permission theo hành động (`permissions`, `role_permissions`, `has_permission`, `my_permissions`), uỷ quyền có thời hạn (`permission_delegations`, `grant_delegation`/`revoke_delegation`), SoD nghiêm (maker ≠ approver, override cần lý do + `policy.override`), đổi `required_approval_level` → `approval_tier`, thêm `actions.automation_level` + `policy_register.max_automation_level` (mặc định L3) | Bắt buộc |
| 10 | `011_measurement.sql` | **Tuần 12‑14**: `action_impact`/`action_impacts` (incremental CP có đối chứng + CI 95%), `pilot_scorecard` (4 bằng chứng, automation rate, incidents), bảng `pilot_reports` | Bắt buộc |
| 4 | `005_data_contract.sql` | **Tuần 1‑2**: `policy_register`, `cogs_history`, `kpi_baseline`, `import_jobs`, cột lead time/nguồn dữ liệu, trigger gán cấp duyệt từ policy, view `v_data_readiness` (gate ≥90%), RPC `capture_kpi_baseline` | Bắt buộc |

Tất cả các file đều idempotent (chạy lại không lỗi). `003_lock_down.sql` đã được gộp vào `004`.

| 14 | `015_connectors_freshness.sql` | **P0‑5**: `data_feeds` (catalog 9 feed: SLA, settlement lag, Amazon report type), `data_sources` (csv_manual / sp_api / ads_api; chỉ `credential_ref`, không secret), `ingestion_runs` (mọi lần lấy dữ liệu; CSV `import_jobs` tự sinh run + backfill), `v_data_freshness` / `feed_is_fresh` / `freshness_summary`, `asin_control_room_v2` (thêm freshness + signal), `upsert_data_source` (cần `policy.edit`) | Bắt buộc |
| 15 | `016_measurement_kpi.sql` | **P0‑6**: `measurements` (baseline đóng băng, đối chứng, thay đổi đồng thời, confidence; final sau cửa sổ + 28 ngày, bất biến), `measure_subject` / `measure_all` / `finalize_measurements`, `content_kpi`, `ai_quality_kpi`, `pilot_scorecard_v2` (chỉ cộng CP từ bản đo moderate/high; confounded không chia attribution) | Bắt buộc |
| 16 | `017_aplus_cvr.sql` | **P1**: `aplus_templates` (4 template toàn cục + theo tenant), `build_aplus_from_template` (điền `{fact:key}` chỉ từ fact verified, tự gắn claims, liệt kê fact thiếu), gate A+ mở rộng (độ dài header/body theo module, image brief, placeholder chưa điền, nhắc đối thủ) bọc quanh gate 013, `content_cvr_series` (CVR theo ngày ±N quanh publish + đối chứng) | Bắt buộc |

## Sau khi chạy 014
Chạy `supabase/tests/014_tasks_control_room_test.sql` → FAIL = 0. UI: menu **Hàng đợi task**; trang SKU có **ASIN Control Room**; tab Ticket VOC có nút **Tạo task →**.

## Sau khi chạy 015
Chạy `supabase/tests/015_connectors_freshness_test.sql` → FAIL = 0. UI: menu **Nguồn dữ liệu** (độ tươi theo feed, đăng ký nguồn API, sổ ingestion_runs); banner ⚠ dữ liệu chưa tươi trên **Tổng quan**; Control Room có tín hiệu "Dữ liệu bắt buộc chưa tươi". Thiết kế: `docs/CONNECTOR_CONTRACT_v0.1.md`.

## Sau khi chạy 013
Chạy `supabase/tests/013_content_studio_test.sql` → toàn bộ `PASS`. UI: menu **Content Studio**.

## Sau khi chạy 012
Chạy `supabase/tests/012_permissions_test.sql` trong SQL Editor — mong đợi toàn bộ `PASS` (script tự ROLLBACK, không để lại dữ liệu). UI: **Cài đặt → Thành viên** hiển thị 7 vai trò, uỷ quyền và ma trận quyền.

## Sau khi chạy 011
Trang Đo lường đọc trực tiếp, không cần cron. Để bằng chứng 3 có số liệu cần ≥3 ngày snapshot trước và sau mỗi lệnh canary/live. Chốt KPI baseline (khối Sẵn sàng dữ liệu trên Tổng quan) để có cột baseline.

## Sau khi chạy 010
Mặc định mọi lệnh chỉ chạy thử. Để pilot: Chính sách → thêm ASIN vào danh sách canary → trên Gợi ý đã duyệt bấm Chạy thử rồi Thực thi canary. Connector hiện là `internal` (cập nhật giá trong hệ thống + audit); khi có SP‑API credentials sẽ thay bằng Edge Function, không đổi schema.

## Sau khi chạy 009
File tự phân loại review hiện có và chạy rule cụm review. Chỉnh từ khoá/chủ đề trong bảng `review_topics`, từ cấm trong `policy_register.prohibited_phrases`. Chưa có review → nhập qua trang Nhập dữ liệu (loại Review khách hàng).

## Sau khi chạy 008
File tự chạy `run_forecasts()` cho mọi tenant ở cuối. Cần ≥ 7 ngày snapshot có `units` để backtest; ít hơn thì dùng số 30 ngày trong danh mục với độ bất định cao. Thứ tự cron: snapshot 03:00 → forecast 03:15 → rules 03:30 UTC.

## Sau khi chạy 007
File tự chạy `run_rules()` một lần cho mọi tenant ở cuối (tạo ngoại lệ + gợi ý ban đầu). Nếu `pg_cron` đã bật, job `vexim_daily_rules` chạy 03:30 UTC (sau snapshot 03:00). Không có pg_cron → dùng nút **Chạy ngay** trên trang Ngoại lệ.

## Sau khi chạy 006 – bật snapshot tự động
Supabase → **Database → Extensions** → bật `pg_cron`, rồi chạy lại `006_snapshots_metrics.sql` (idempotent) để đăng ký job `vexim_daily_snapshots` lúc 03:00 UTC. Nếu không bật được, dùng nút **Chụp snapshot hôm nay** trên Tổng quan mỗi ngày.

## Sau khi chạy 004 – thiết lập owner đầu tiên (1 lần)

1. Supabase → **Authentication → Providers → Email**: bật *Email* (magic link mặc định bật; bật thêm *Password* nếu muốn).
2. Supabase → **Authentication → URL Configuration**: thêm `https://<domain-app>/auth/callback` (và `http://localhost:3000/auth/callback`) vào *Redirect URLs*.
3. Mở app → `/login` → đăng nhập bằng email của bạn 1 lần (để `auth.users` có bản ghi). Bạn sẽ thấy màn "Tài khoản chưa thuộc brand nào".
4. Chạy trong SQL Editor:
   ```sql
   INSERT INTO public.tenant_members (tenant_id, user_id, role)
   SELECT t.id, u.id, 'owner'
   FROM public.tenants t, auth.users u
   WHERE t.slug = 'vexim' AND lower(u.email) = lower('you@example.com')
   ON CONFLICT (tenant_id, user_id) DO UPDATE SET role = 'owner';
   ```
5. Tải lại app. Từ đây thêm thành viên khác qua **Thành viên** (người đó cần đăng nhập 1 lần trước).

## Mô hình quyền

| Vai trò (theo brand) | Xem | Thêm/sửa SKU, gửi gợi ý, xử lý ngoại lệ | Duyệt L0/L1 | Duyệt L2 | Quản lý thành viên |
|---|---|---|---|---|---|
| viewer | ✅ | ❌ | ❌ | ❌ | ❌ |
| operator | ✅ | ✅ | L0 | ❌ | ❌ |
| ops_lead | ✅ | ✅ | L0–L1 | ❌ | ❌ |
| finance | ✅ | COGS/đối soát | ❌ | ❌ | ❌ |
| content_qa | ✅ | content/VoC | ❌ | ❌ | ❌ |
| brand_approver | ✅ | content | ❌ | ❌ | ❌ |
| owner | ✅ | ✅ | L0–L2 | ✅ | ✅ |

Từ 012, quyền là **permission theo hành động** (`SELECT * FROM v_role_matrix`), không chỉ role. Nguyên tắc tách trách nhiệm được enforce ở DB: người tạo/gửi không tự duyệt; người soạn phản hồi không tự duyệt.

Quyền được kiểm tra **ở database** (RLS + trigger `guard_recommendation_transition`), UI chỉ ẩn/khoá nút cho tiện. Từ chối/hoàn tác bắt buộc có lý do. Mọi insert/update/delete trên `amazon_skus`, `recommendations`, `exceptions` được ghi vào `audit_log` (ai, khi nào, before/after).

## Thêm brand mới
```sql
INSERT INTO public.tenants (slug, name, marketplace) VALUES ('brand-b', 'Brand B', 'US');
-- rồi thêm owner cho brand đó như bước 4 ở trên, đổi slug.
```

## Biến môi trường
Xem `.env.example`. Thêm vào `.env.local` (local) và Vercel → Settings → Environment Variables (deploy), rồi redeploy.

## Sau khi chạy 016
Chạy `supabase/tests/016_measurement_kpi_test.sql` → FAIL = 0. UI: trang **Đo lường** có thêm 2 thẻ KPI Content / KPI chất lượng AI và **Sổ đo lường** (nút "Đo lại" gọi `measure_all` + `finalize_measurements`).
| 17 | `018_aplus_fidelity.sql` | **P1 – A+ bám cấu trúc Amazon**: `aplus_module_specs` (17 module Standard/Premium đúng tên & giới hạn ký tự/ảnh của A+ Content Manager), `policy_register.aplus_premium_enabled` (Standard ≤ 5 module, Premium ≤ 7), `aplus_upgrade_body` (nâng body header/body cũ), `check_aplus_modules_v2` (kiểm tra đệ quy từng trường theo spec, alt‑text, giá/khuyến mãi, link ngoài, claim tuyệt đối, so sánh chỉ ASIN cùng tenant), `build_aplus_from_template` v2 (điền `{fact:key}` trong mọi trường lồng nhau), 4 template toàn cục viết lại trên module thật | Bắt buộc |
| 18 | `019_phase0_truthfulness.sql` | **Phase 0 – Truthfulness**: `actions.execution_channel` (internal_record / manual_seller_central / sp_api) + `amazon_applied`; bỏ `submission_id` giả; `execute_recommendation` v3 khoá live khi chưa có sp_api connected; `confirm_manual_execution` (xác nhận đã làm tay kèm bằng chứng); `publish_records` + `record_publish/record_rollback` + policy `publish_evidence_required` (guard chặn UPDATE thẳng sang published); `system_health()` (pg_cron ok/missing/unknown) | Bắt buộc |
| 19 | `020_canonical_data.sql` | **Phase 1a – Canonical data**: bảng `orders`, `returns`, `ad_campaigns/ad_groups/ad_keywords/ad_daily`, `search_terms`, `promotions`, `traffic_daily`, `inventory_ledger` (tenant + marketplace, natural key, `source_record_hash`, RLS chỉ SELECT); 4 feed mới trong `data_feeds`; `derive_snapshots()` canonical → `sku_daily_snapshots`; `v_data_freshness` đọc ngày dữ liệu từ bảng canonical | Bắt buộc |
| 20 | `021_ingestion.sql` | **Phase 1b – Server-side ingestion**: `ingest_feed_specs` (hợp đồng schema v1, CSV = API), staging `ingest_batches/ingest_rows`, RPC `ingest_open` → `ingest_add_rows` → `ingest_dry_run` → `ingest_commit` (validate từng dòng, idempotent theo file_hash + row hash, 1 dòng lỗi không mất batch, ghi `ingestion_runs`, derive snapshots). **Xoá policy `snap_write`** — trình duyệt không còn ghi `sku_daily_snapshots` | Bắt buộc |
| 21 | `022_close_direct_writes.sql` | **Phase 1c – Đóng đường ghi trực tiếp**: 6 feed cũ (catalog/cogs/sales/inventory/fees/reviews) đi qua `ingest_*`; `sku_save()` (RPC duy nhất thêm/sửa/lưu trữ SKU + COGS, kiểm `sku.write`/`cogs.write`); `run_reconciliation_auto()` orders ↔ traffic_daily theo ASIN; **xoá policy ghi** trên `amazon_skus`, `raw_reviews`, `cogs_history`, `import_jobs` | Bắt buộc |

## Sau khi chạy 017
Chạy `supabase/tests/017_aplus_cvr_test.sql` → FAIL = 0. UI: Content Studio → tab A+ → "Draft mới" có ô **Template A+**; nút "Tác động" của bản published hiện thêm **biểu đồ CVR trước/sau** kèm đường đối chứng.

## Sau khi chạy 018
Chạy `supabase/tests/018_aplus_fidelity_test.sql` → FAIL = 0. UI: Content Studio → tab A+ → editor theo **module Amazon** (chọn module, thứ tự, đếm ký tự theo giới hạn thật, brief ảnh + alt‑text, bảng specs/so sánh), **Preview desktop/mobile**, và nút **⇩ Gói bàn giao Seller Central (.md)** trên bản approved/published để copy 1:1 vào A+ Content Manager. Bật Premium A+: `UPDATE policy_register SET aplus_premium_enabled = true WHERE tenant_id = ...`.

## Sau khi chạy 019
Chạy `supabase/tests/019_phase0_test.sql` → FAIL = 0. Lưu ý: test 013/016/017 publish bằng UPDATE trực tiếp nên đã được cập nhật để tắt `publish_evidence_required` cho tenant test. UI: Lệnh thực thi hiển thị kênh ("Ghi nhận nội bộ — chưa tác động Amazon" / "Đã thực hiện tay trên Seller Central"), nút Live bị khoá; Content Studio: "Ghi nhận đã publish (kèm bằng chứng)"; Tổng quan → Kết nối dữ liệu: trạng thái pg_cron & Write‑back TẮT.

## Sau khi chạy 020 + 021
Chạy `supabase/tests/021_ingestion_test.sql` → FAIL = 0. UI: Nhập dữ liệu → nhóm "Vận hành theo ngày"/"Quảng cáo" có 7 feed gắn nhãn **kiểm tra trước khi ghi** (Đơn hàng, Quảng cáo, Sessions, Trả hàng, Search term, Khuyến mãi, Sổ tồn kho): bước 3 = **Kiểm tra (không ghi)** → xem lỗi từng dòng / ASIN lạ / ngày đã có dữ liệu → **Ghi**. Nhập lại cùng file → báo trùng, không ghi lại. Feed cũ (Danh mục, COGS, Doanh số 30d, Tồn kho, Phí, Review) vẫn ghi trực tiếp — sẽ chuyển sang RPC ở Phase 1c.

## Sau khi chạy 022
Chạy `supabase/tests/022_close_direct_writes_test.sql` → FAIL = 0. Từ đây **client không còn INSERT/UPDATE bảng dữ liệu nào** (chỉ SELECT + RPC). UI: mọi loại nhập đều qua Kiểm tra → Ghi; Thêm SKU / sửa SKU dùng `sku_save`; Đối soát có nút **Đối soát tự động: Đơn hàng ↔ Business report**.
