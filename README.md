# Vexim Amazon Managed Operations

Control plane nội bộ cho vận hành Amazon theo vòng lặp **Data → Margin → Decision → Risk → Approval → Action → Measurement**, human‑in‑the‑loop, multi‑tenant.

> Trạng thái (2026‑09): **Development/Staging.** Chưa có kết nối SP‑API/Ads API thật; dữ liệu vào bằng CSV. Mọi thay đổi giá/PO/content đều **thực hiện tay trên Seller Central** và được hệ thống **ghi nhận kèm bằng chứng** — không có write‑back. Xem `docs/AUDIT_HIEN_TRANG_2026-09-10.md` và kế hoạch phase trong `docs/PRODUCT_SCOPE_v0.1.md`.

## Kiến trúc
- **Frontend:** Next.js 16 (App Router, Turbopack), React 19, Tailwind v4, recharts. Không có API server riêng — client gọi Supabase trực tiếp bằng anon key + RLS.
- **Backend:** Supabase Postgres. Toàn bộ nghiệp vụ nằm trong SQL (`supabase/0xx_*.sql`): function `SECURITY DEFINER` (đều có `SET search_path`), trigger guard, RLS theo tenant, pg_cron cho snapshot/rule/forecast.
- **Auth:** Supabase Auth; `proxy.ts` bảo vệ route; 7 role tenant‑scoped + permission theo action (`012_permissions.sql`).

## Chạy local
```bash
cp .env.example .env.local   # điền NEXT_PUBLIC_SUPABASE_URL / ANON_KEY
npm ci
npm run dev                  # http://localhost:3000
```
Kiểm tra trước khi commit: `npx tsc --noEmit` (bỏ qua lỗi LayoutProps/PageProps của Next 16) và `npx eslint .`. `next build` cần mạng để tải font Geist.

## Database
1. Supabase → SQL Editor, chạy lần lượt `supabase/001_schema.sql` → `004` → … → `019` (bỏ `002_seed.sql` — đã lỗi thời; dùng `002b_seed_tenant.sql` nếu cần demo). Thứ tự và mô tả từng file: `supabase/README.md`.
2. Bật extension `pg_cron` (Database → Extensions) rồi chạy lại 006/007/008 để đăng ký 3 job `vexim_*`. Trạng thái cron hiển thị ở Tổng quan → "Kết nối dữ liệu" (OK / THIẾU / KHÔNG XÁC ĐỊNH — không giả định).
3. Test: chạy từng file `supabase/tests/0xx_*_test.sql` trong SQL Editor; kết quả in ra dưới dạng exception, kỳ vọng `0 FAIL`. Test chạy với role postgres (bypass RLS) — RLS được kiểm qua `pg_policies`/`has_permission`.

## Deploy
Vercel, framework Next.js, env `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`; Supabase Auth redirect `/auth/callback`. Không đặt service_role hay secret Amazon vào Vercel/client — Phase 2 dùng Edge Function secrets.

## Nguyên tắc không thương lượng
- `approval_tier` (cấp duyệt) tách khỏi `automation_level` (mức tự động hoá). Live (L4) bị khoá khi tenant chưa có `data_sources` sp_api `connected`.
- Maker ≠ approver (SoD) — override chỉ với `policy.override` + lý do, có audit.
- Content chỉ `published` qua `record_publish()` kèm bằng chứng (policy `publish_evidence_required`, mặc định bật).
- Không có Brand Approver → content dừng ở `awaiting_brand_approval`.
- Dữ liệu thiếu hiển thị "chưa có/stale", không hiển thị 0 giả.

## Tài liệu
`docs/OPERATING_GOVERNANCE_v0.1.md` · `docs/PRODUCT_SCOPE_v0.1.md` · `docs/CONNECTOR_CONTRACT_v0.1.md` · `docs/AUDIT_HIEN_TRANG_2026-09-10.md`

## Connector Amazon (Phase 2)
Xem `docs/RUNBOOK_CONNECTORS.md` — deploy Edge Function `amazon-sync`, lưu credential vào Vault, backfill 1/7/28 ngày. Chỉ đọc; không write‑back.
