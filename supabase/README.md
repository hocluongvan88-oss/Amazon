# Supabase — thứ tự chạy SQL

Vào **Supabase Dashboard → SQL Editor → New query**, dán từng file và bấm **Run**:

| Thứ tự | File | Nội dung | Khi nào |
|---|---|---|---|
| 1 | `001_schema.sql` | Bảng, index, trigger, RLS cơ bản, view | Bắt buộc |
| 2 | `002_seed.sql` | 8 SKU mẫu + review + gợi ý + ngoại lệ | Khuyến nghị cho pilot/demo |
| 3 | `004_tenancy_auth.sql` | **Sprint 0**: tenants, `tenant_id` mọi bảng, RLS theo tenant, guard chuyển trạng thái theo cấp duyệt, audit trigger, gỡ quyền `anon` | Bắt buộc trước khi cho người dùng thật vào |
| 5 | `006_snapshots_metrics.sql` | **Tuần 3‑4**: `sku_daily_snapshots` (grain SKU×ngày), `capture_daily_snapshots` + lịch pg_cron 03:00 UTC, `sku_metrics()` & `tenant_daily()` (metric layer), `refresh_sku_rolling_from_snapshots`, `reconciliation_checks` + `run_reconciliation`, view `v_data_connections` | Bắt buộc |
| 6 | `007_risk_rules.sql` | **Tuần 5‑6**: `risk_score`/`risk_components`/`risk_history`, `compute_risk_score`, rule engine `run_rules` (8 rule, dedupe/cooldown/auto‑resolve, pg_cron 03:30 UTC), SLA ngoại lệ (`due_at`, `assigned_to`, `snoozed_until`, feedback), `rule_runs`, views `v_exception_queue`/`v_rule_precision`, `profit_bridge()` | Bắt buộc |
| 7 | `008_forecast_inventory.sql` | **Tuần 7‑8**: `inventory_inbound`, `forecasts`/`forecast_backtests`, `forecast_sku`/`run_forecasts` (pg_cron 03:15 UTC), `inventory_plan(t, lead_time, safety, p90, inbound)` cho trang Tồn kho & scenario, `replenish_rationale`, `run_rules` bản mới dùng forecast, view `v_forecast_accuracy` | Bắt buộc |
| 8 | `009_reviews_voc.sql` | **Tuần 9‑10**: `review_topics` (seed 13 chủ đề), `review_classifications` + `classify_review(s)` (trigger khi insert review), `voc_tickets`, `response_drafts` + `check_response_policy` + guard duyệt (người duyệt ≠ người soạn, chặn từ cấm), `suggest_response`, views `v_review_triage`/`v_review_topic_summary`/`v_classification_precision`, rule `REVIEW_CLUSTER`, policy `prohibited_phrases` | Bắt buộc |
| 9 | `010_actions.sql` | **Tuần 11**: `actions` + `rollbacks` (idempotency, dry_run/canary/live, guard chặn ghi trực tiếp), `execute_recommendation(rec, mode)`, `rollback_action`, `check_auto_rollbacks` (cron 03:30), view `v_automation_stats`, policy `automation_live`/`canary_asins`/`rollback_watch_hours`/`rollback_units_drop_pct`/`max_live_actions_per_day` | Bắt buộc |
| 11 | `012_permissions.sql` | **P0‑1**: 7 role tenant‑scoped, permission theo hành động (`permissions`, `role_permissions`, `has_permission`, `my_permissions`), uỷ quyền có thời hạn (`permission_delegations`, `grant_delegation`/`revoke_delegation`), SoD nghiêm (maker ≠ approver, override cần lý do + `policy.override`), đổi `required_approval_level` → `approval_tier`, thêm `actions.automation_level` + `policy_register.max_automation_level` (mặc định L3) | Bắt buộc |
| 10 | `011_measurement.sql` | **Tuần 12‑14**: `action_impact`/`action_impacts` (incremental CP có đối chứng + CI 95%), `pilot_scorecard` (4 bằng chứng, automation rate, incidents), bảng `pilot_reports` | Bắt buộc |
| 4 | `005_data_contract.sql` | **Tuần 1‑2**: `policy_register`, `cogs_history`, `kpi_baseline`, `import_jobs`, cột lead time/nguồn dữ liệu, trigger gán cấp duyệt từ policy, view `v_data_readiness` (gate ≥90%), RPC `capture_kpi_baseline` | Bắt buộc |

Tất cả các file đều idempotent (chạy lại không lỗi). `003_lock_down.sql` đã được gộp vào `004`.

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
