# Supabase — thứ tự chạy SQL

Vào **Supabase Dashboard → SQL Editor → New query**, dán từng file và bấm **Run**:

| Thứ tự | File | Nội dung | Khi nào |
|---|---|---|---|
| 1 | `001_schema.sql` | Bảng, index, trigger, RLS cơ bản, view | Bắt buộc |
| 2 | `002_seed.sql` | 8 SKU mẫu + review + gợi ý + ngoại lệ | Khuyến nghị cho pilot/demo |
| 3 | `004_tenancy_auth.sql` | **Sprint 0**: tenants, `tenant_id` mọi bảng, RLS theo tenant, guard chuyển trạng thái theo cấp duyệt, audit trigger, gỡ quyền `anon` | Bắt buộc trước khi cho người dùng thật vào |
| 5 | `006_snapshots_metrics.sql` | **Tuần 3‑4**: `sku_daily_snapshots` (grain SKU×ngày), `capture_daily_snapshots` + lịch pg_cron 03:00 UTC, `sku_metrics()` & `tenant_daily()` (metric layer), `refresh_sku_rolling_from_snapshots`, `reconciliation_checks` + `run_reconciliation`, view `v_data_connections` | Bắt buộc |
| 6 | `007_risk_rules.sql` | **Tuần 5‑6**: `risk_score`/`risk_components`/`risk_history`, `compute_risk_score`, rule engine `run_rules` (8 rule, dedupe/cooldown/auto‑resolve, pg_cron 03:30 UTC), SLA ngoại lệ (`due_at`, `assigned_to`, `snoozed_until`, feedback), `rule_runs`, views `v_exception_queue`/`v_rule_precision`, `profit_bridge()` | Bắt buộc |
| 4 | `005_data_contract.sql` | **Tuần 1‑2**: `policy_register`, `cogs_history`, `kpi_baseline`, `import_jobs`, cột lead time/nguồn dữ liệu, trigger gán cấp duyệt từ policy, view `v_data_readiness` (gate ≥90%), RPC `capture_kpi_baseline` | Bắt buộc |

Tất cả các file đều idempotent (chạy lại không lỗi). `003_lock_down.sql` đã được gộp vào `004`.

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
| operator | ✅ | ✅ | ✅ | ❌ | ❌ |
| owner | ✅ | ✅ | ✅ | ✅ | ✅ |

Quyền được kiểm tra **ở database** (RLS + trigger `guard_recommendation_transition`), UI chỉ ẩn/khoá nút cho tiện. Từ chối/hoàn tác bắt buộc có lý do. Mọi insert/update/delete trên `amazon_skus`, `recommendations`, `exceptions` được ghi vào `audit_log` (ai, khi nào, before/after).

## Thêm brand mới
```sql
INSERT INTO public.tenants (slug, name, marketplace) VALUES ('brand-b', 'Brand B', 'US');
-- rồi thêm owner cho brand đó như bước 4 ở trên, đổi slug.
```

## Biến môi trường
Xem `.env.example`. Thêm vào `.env.local` (local) và Vercel → Settings → Environment Variables (deploy), rồi redeploy.
