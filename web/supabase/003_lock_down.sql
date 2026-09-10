-- ============================================================
-- Chạy file này KHI ĐÃ BẬT ĐĂNG NHẬP (Supabase Auth) trong app.
-- Gỡ các policy cho phép `anon` (chế độ pilot) → chỉ user đăng nhập truy cập.
-- ============================================================
DROP POLICY IF EXISTS skus_pilot_anon_all          ON public.amazon_skus;
DROP POLICY IF EXISTS reviews_pilot_anon_select    ON public.raw_reviews;
DROP POLICY IF EXISTS recs_pilot_anon_all          ON public.recommendations;
DROP POLICY IF EXISTS exceptions_pilot_anon_select ON public.exceptions;
REVOKE SELECT ON public.v_sku_overview FROM anon;

-- Gán quyền admin cho tài khoản của bạn (thay email):
-- UPDATE public.profiles SET role = 'admin' WHERE email = 'you@example.com';
