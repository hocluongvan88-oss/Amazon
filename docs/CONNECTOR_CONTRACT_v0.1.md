# Data Connector Contract v0.1

> Kết luận nghiên cứu (10/9/2026) và hợp đồng kỹ thuật cho mọi nguồn dữ liệu.
> Mục tiêu: **CSV là bootstrap/fallback; SP‑API / Ads API là kiến trúc chính** — nhưng cả hai cùng đi qua một
> mô hình duy nhất: `data_source → ingestion_run → normalized tables → metrics → rules → action queue`.

## 1. Phát hiện quan trọng từ nghiên cứu

| # | Phát hiện | Hệ quả thiết kế |
|---|---|---|
| 1 | SP‑API Reports là **bất đồng bộ**: `createReport` → poll `getReport` (processingStatus) → `getReportDocument` (gzip). Rate limit rất thấp: createReport/getReportDocument **0.0167 req/s (≈1 phút/request), burst 15**; getReport 2 req/s. | `ingestion_runs` phải có trạng thái `queued/running`, `external_ref` (reportId), retry/backoff; **không gọi API trực tiếp từ browser**; scheduler chạy server‑side (Edge Function/cron) với hàng đợi. |
| 2 | Report type map: Orders → `GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL` (tab‑delimited; MFN+FBA); Sales & Traffic → `GET_SALES_AND_TRAFFIC_REPORT` (JSON, cần role **Brand Analytics**, `asinGranularity=CHILD`, `dateGranularity=DAY`, tối đa 2 năm); Tồn kho FBA → `GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA`. | Feed catalog trong DB ghi rõ `amazon_report_type` để P2 chỉ cần implement connector, không đổi schema. Sales & Traffic là feed **mới** (sessions/page views/buy box theo ngày) → bổ sung feed `sales_traffic_daily`. |
| 3 | Ads API: dữ liệu **không real‑time**; Amazon khuyến nghị lấy sau **72 h** để khớp console; click validation 1–3 ngày; **restatement conversion ở ngày 1, 7, 28** sau sự kiện → với attribution 14 ngày, số liệu có thể đổi tới **42 ngày** sau. Chỉ trả 1 ngày/request. | Feed `ads_daily` có `settlement_lag_days = 3` và **lookback re‑pull** (1, 3, 7, 14, 30 ngày). Freshness của ads tính trên ngày "đã settle" (`today − 3`), không phải hôm qua. `sku_daily_snapshots.sources` ghi `{"ads":"csv"|"ads_api"}` và `ingestion_runs.window_*` cho biết khoảng nào đã được restate. |
| 4 | Orders theo UTC; Business Report theo múi giờ marketplace. | Đối soát ≥ 7 ngày (đã có). Feed metadata lưu `timezone_note`. |
| 5 | Credential (LWA refresh token, Ads profile) **không được** nằm trong bảng thường. | `data_sources.credential_ref` chỉ là *tên khoá* trong Supabase Vault / secret của Edge Function; RLS không bao giờ trả secret. |

## 2. Mô hình

```
data_feeds (catalog cố định)      data_sources (instance / tenant)      ingestion_runs (mỗi lần lấy)
 feed_key, domain, sla_hours,  ←  kind: csv_manual | sp_api | ads_api  ←  source_id, feed_key, status,
 settlement_lag_days,              enabled, config (marketplace,           window_start/end, rows_*,
 amazon_report_type,               profile_id…), credential_ref,           errors, external_ref,
 required_for_readiness            schedule_cron, last_run_at              triggered_by, idempotency_key
```

- **import_jobs** (CSV hiện tại) không bị bỏ: trigger tự tạo `ingestion_runs` tương ứng với nguồn `csv_manual` của tenant → UI nhập liệu hiện có tiếp tục hoạt động, nhưng freshness/observability nhìn thấy mọi nguồn như nhau.
- **Freshness** (`v_data_freshness`): per tenant × feed → `last_success_at`, `last_data_date` (lấy từ *bảng dữ liệu thật*, không chỉ từ log run), `age_hours`, `sla_hours`, `status ∈ fresh | stale | missing`, `settled_through` (ads).
- **Gate**: `feed_is_fresh(t, feed)` cho rule engine / measurement dùng; Dashboard & Control Room hiển thị banner stale.

## 3. Feed catalog (v0.1)

| feed_key | domain | SLA (giờ) | settle lag | Amazon report / API | Ghi chú |
|---|---|---|---|---|---|
| catalog | data | 168 | 0 | Listings Items API / Merchant Listings report | ASIN, tên, giá, SKU |
| cogs | finance | 720 | 0 | — (kế toán) | chỉ Finance |
| fees | finance | 720 | 0 | `GET_FBA_ESTIMATED_FBA_FEES_TXT_DATA` | FBA fee, referral % |
| inventory | inventory | 48 | 0 | `GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA` | khả dụng + inbound |
| orders_daily | revenue | 36 | 1 | `GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL` | bỏ Cancelled; UTC |
| sales_traffic_daily | revenue | 48 | 1 | `GET_SALES_AND_TRAFFIC_REPORT` (CHILD, DAY) | sessions, page views, buy box % |
| sales_30d | revenue | 168 | 0 | Business Report export | fallback khi chưa có daily |
| ads_daily | ads | 96 | 3 | Ads API v3 reports (SP campaigns/advertised product) | lookback 1/3/7/14/30 |
| reviews | voc | 168 | 0 | (không có API review chính thức) — upload | chỉ lắng nghe |

## 4. Interface (TypeScript, `lib/connectors/types.ts`)

```ts
interface Connector {
  kind: 'csv_manual' | 'sp_api' | 'ads_api';
  feeds: FeedKey[];
  /** Kéo 1 feed cho 1 cửa sổ; trả về batch đã chuẩn hoá — KHÔNG ghi DB trực tiếp */
  pull(ctx: PullContext, feed: FeedKey, window: DateWindow): Promise<NormalizedBatch>;
}
```
`NormalizedBatch` là hợp đồng duy nhất mà tầng ghi (`applyBatch`) hiểu → logic nghiệp vụ không bao giờ phụ thuộc định dạng file hay API.

## 5. Ngoài phạm vi P0‑5 (P2)
Implement `sp_api` / `ads_api` connector (Edge Function + Vault), scheduler cron, retry/backoff theo rate limit, lookback re‑pull ads, Marketing Stream (near real‑time) nếu cần.
