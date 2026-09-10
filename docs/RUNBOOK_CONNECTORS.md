# Runbook — Connector Amazon (Phase 2, chỉ đọc)

> Áp dụng cho môi trường Dev/Staging. Không có hành động ghi lên Amazon trong toàn bộ luồng này.

## 1. Kiến trúc

```
UI (Nguồn kết nối)  ──credential──▶  Edge Function amazon-sync ──▶ Supabase Vault (secret)
        │ backfill/enqueue                    │ claim_sync_job (service_role)
        ▼                                     ▼
   sync_jobs (hàng đợi)  ◀── pg_cron 10' ──  worker: LWA → createReport → poll → download → parse
                                              │
                                              ▼
                              ingest_open/add_rows/dry_run/commit  (cùng hợp đồng với CSV)
                                              │
                                              ▼
                     orders / traffic_daily / returns / inventory_ledger / ad_daily / search_terms
                                              │ derive_snapshots
                                              ▼
                                   sku_daily_snapshots → dashboards
```

- Secret chỉ tồn tại trong Vault và trong bộ nhớ của Edge Function trong 1 lần chạy. Bảng `data_sources` chỉ giữ `credential_ref`.
- Mọi lỗi phân loại: `auth` / `permission` (không retry, nguồn chuyển `error`), `rate_limit` / `amazon` / `network` (retry với backoff `60s × attempt²`, tối đa 5 lần).
- Report Amazon trả 0 dòng → run `succeeded` với `rows=0`, **không ghi 0** vào bảng dữ liệu.

## 2. Yêu cầu phía Amazon

| Feed | API | Quyền / role cần |
|---|---|---|
| orders_daily | SP‑API Reports `GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL` | Role "Selling Partner Insights"/Orders (đọc) |
| sales_traffic_daily | SP‑API Reports `GET_SALES_AND_TRAFFIC_REPORT` (CHILD, DAY) | Role **Brand Analytics** (chỉ brand owner) |
| inventory_ledger | SP‑API Reports `GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA` | Amazon Fulfillment |
| returns | SP‑API Reports `GET_FBA_FULFILLMENT_CUSTOMER_RETURNS_DATA` | Amazon Fulfillment |
| ads_daily | Ads API v3 `spAdvertisedProduct` DAILY | LWA scope `advertising::campaign_management` (đọc report) |
| search_terms | Ads API v3 `spSearchTerm` DAILY | như trên |
| promotions | — | Nhập tay có audit (chưa có API ổn định) |

Chuẩn bị: ứng dụng SP‑API (private/self‑authorized cho Dev) → `client_id`, `client_secret`, `refresh_token` của seller. Với Ads: ứng dụng LWA đã được duyệt Ads API + refresh token có scope quảng cáo; profile ID sẽ được liệt kê khi thử kết nối.

## 3. Cài đặt (1 lần / project)

1. Chạy migration `supabase/023_connectors_sync.sql`; chạy test `supabase/tests/023_connectors_sync_test.sql` → `0 FAIL`.
2. Bật extension: **vault** (mặc định có), **pg_net**, **pg_cron** (Dashboard → Database → Extensions).
3. Deploy function:
   ```bash
   supabase functions deploy amazon-sync --project-ref kcafwjepioaicvmasqca
   ```
   Function dùng các env mặc định `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` (Supabase tự cấp). Không cần secret Amazon ở env.
4. Lịch tự động (tuỳ chọn nhưng khuyến nghị) — SQL Editor:
   ```sql
   SELECT public.connector_secret_put('vexim:project_url', 'https://kcafwjepioaicvmasqca.supabase.co');
   SELECT public.connector_secret_put('vexim:service_role_key', '<service_role key>');
   SELECT public.install_sync_cron('*/10 * * * *');   -- trả 'ok'
   ```
   Cron gọi `amazon-sync` với `{action:'tick', max_jobs:5}`. Để tự xếp job theo lookback mỗi ngày, thêm:
   ```sql
   SELECT cron.schedule('vexim_amazon_schedule', '15 3 * * *', $$SELECT public.schedule_sync_jobs()$$);
   ```

## 4. Kết nối 1 tenant (người có `policy.edit`)

1. Tổng quan → Kết nối dữ liệu → **+ Đăng ký nguồn API** → chọn SP‑API hoặc Ads API, chọn feed → Lưu.
2. Trong nguồn vừa tạo → **Nhập credential** → dán LWA client id/secret + refresh token → **Lưu vào Vault và thử kết nối**.
   - SP‑API: worker gọi `getReports` (đọc) để xác minh; lưu `region`, `marketplace_id`, `verified_at` vào `config`.
   - Ads API: liệt kê profile; nếu >1 profile, nhập lại kèm Ads profile ID.
3. Trạng thái nguồn chuyển **Đã kết nối**. Chưa kết nối thì không xếp được job.

## 5. Kéo dữ liệu (người có `data.import`)

- Chọn feed → **Backfill 1 / 7 / 28 ngày** → job xuất hiện trong "Job đồng bộ API".
- **Chạy ngay** xử lý tối đa 2 job tức thì (không chờ cron). Sales & Traffic và Ads là 1 ngày/job; orders/returns 7 ngày/job.
- Kiểm tra: "Lần lấy dữ liệu gần đây" có run với `triggered_by = backfill/schedule`, `external_ref = reportId`; Độ tươi theo feed cập nhật `Dữ liệu tới ngày`.
- Đối soát: Nhập dữ liệu → Đối soát → **Đối soát tự động: Đơn hàng ↔ Business report**.

## 6. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `[xác thực] LWA 400 invalid_grant` | refresh token sai/hết hạn/ứng dụng bị thu hồi | Nhập lại credential |
| `[thiếu quyền/role Amazon] Amazon 403` | thiếu role (Brand Analytics cho Sales&Traffic) | Xin role trong Developer Central, seller authorize lại |
| Job `chờ` lâu, Worker "chưa xác định" | function chưa deploy hoặc cron chưa cài | Mục 3; hoặc bấm "Chạy ngay" |
| `Report chưa xong — thử lại sau` lặp | Amazon xử lý báo cáo chậm (bình thường với Sales&Traffic) | Job giữ `reportId` và tự poll lại; không tạo report mới |
| Ads `[giới hạn tần suất]` | rate limit | tự retry sau 90s |
| `Không có dòng hợp lệ` | định dạng report đổi | xem `ingest_batches.summary.errors`, báo dev |

## 7. Bảo mật / kiểm toán

- `connector_secret_get/put/delete`, `claim_sync_job`, `finish_sync_job`, `set_source_status`, `schedule_sync_jobs` **chỉ service_role**; test 023 kiểm tra không cấp cho `authenticated/anon`.
- Lưu credential ghi `audit_log` (`connector.credential_stored`, không kèm giá trị).
- Không endpoint nào của function gọi API ghi Amazon; `connector_health().write_back_enabled = false`.
