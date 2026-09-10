# Supabase — thứ tự chạy SQL

Vào **Supabase Dashboard → SQL Editor → New query**, dán từng file và bấm **Run**:

| Thứ tự | File | Nội dung | Khi nào |
|---|---|---|---|
| 1 | `001_schema.sql` | Bảng, index, trigger, RLS, view `v_sku_overview` | Bắt buộc, chạy đầu tiên |
| 2 | `002_seed.sql` | 8 SKU mẫu + review + gợi ý + ngoại lệ | Khuyến nghị cho pilot/demo |
| 3 | `003_lock_down.sql` | Gỡ quyền `anon` | Chỉ khi app đã có đăng nhập |

Cả 3 file đều chạy lại được nhiều lần mà không lỗi.

## Bảng

- `profiles` – hồ sơ user + role (`admin` / `operator` / `viewer`), tự tạo khi user đăng ký
- `amazon_skus` – danh mục ASIN, giá, COGS, phí; `contribution_profit` tự tính
- `raw_reviews` – review thô
- `recommendations` – gợi ý (price_adjust / replenish / review_response / inventory_transfer), luồng duyệt L0/L1/L2
- `exceptions` – hàng đợi ngoại lệ P0–P3
- `audit_log` – nhật ký hành động

## Lưu ý về RLS

App hiện **chưa có đăng nhập** và dùng anon key, nên `001_schema.sql` mở quyền cho role `anon`
trên `amazon_skus` / `recommendations` (đọc + ghi) và `raw_reviews` / `exceptions` (chỉ đọc).
Đây là chế độ pilot — **không dùng cho production**. Khi bật Auth hãy chạy `003_lock_down.sql`.

## Biến môi trường

```
NEXT_PUBLIC_SUPABASE_URL=https://<project>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon key>
```
Lấy tại Supabase → Project Settings → API. Thêm vào `.env.local` (local) và Vercel → Settings → Environment Variables (deploy), rồi redeploy.
