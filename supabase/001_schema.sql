-- ============================================================
-- Vexim Amazon Managed Operations — Supabase schema
-- File 1/2: chạy TRƯỚC trong Supabase → SQL Editor → New query → Run
-- Script này idempotent: chạy lại nhiều lần không lỗi.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Hàm tiện ích: tự cập nhật updated_at
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 1. profiles / RBAC  (roles: admin | operator | viewer)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       TEXT,
  full_name   TEXT,
  role        TEXT NOT NULL DEFAULT 'viewer'
              CHECK (role IN ('admin','operator','viewer')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Tự tạo profile khi có user mới đăng ký (role mặc định: viewer)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data ->> 'full_name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Helper: kiểm tra role của user hiện tại (dùng trong RLS)
CREATE OR REPLACE FUNCTION public.current_role_in(roles TEXT[])
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = ANY (roles)
  );
$$;

-- ------------------------------------------------------------
-- 2. amazon_skus — danh mục ASIN/SKU & chỉ số
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.amazon_skus (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asin                 TEXT NOT NULL,
  sku                  TEXT,
  title                TEXT NOT NULL,
  marketplace          TEXT NOT NULL DEFAULT 'US',
  -- Chi phí & giá
  cogs                 NUMERIC(12,2) NOT NULL DEFAULT 0,
  current_price        NUMERIC(12,2) NOT NULL DEFAULT 0,
  list_price           NUMERIC(12,2),
  fee_per_unit         NUMERIC(12,2) NOT NULL DEFAULT 0,   -- FBA fee
  referral_fee_pct     NUMERIC(5,2)  NOT NULL DEFAULT 15.00,
  -- Chỉ số suy ra: lợi nhuận góp phần / đơn vị
  contribution_profit  NUMERIC(12,2) GENERATED ALWAYS AS
                       (current_price - cogs - fee_per_unit - current_price * referral_fee_pct / 100) STORED,
  -- Bán hàng
  sales_last_30d       INTEGER NOT NULL DEFAULT 0,
  avg_order_value      NUMERIC(12,2),
  -- Rủi ro & sức khỏe
  margin_delta         NUMERIC(8,2) NOT NULL DEFAULT 0,    -- thay đổi so với baseline
  inventory_qty        INTEGER NOT NULL DEFAULT 0,
  reorder_point        INTEGER NOT NULL DEFAULT 0,
  stockout_risk_score  NUMERIC(5,2) NOT NULL DEFAULT 0
                       CHECK (stockout_risk_score BETWEEN 0 AND 100),
  price_volatility     NUMERIC(5,2) NOT NULL DEFAULT 0,
  -- Thời gian
  last_ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (asin, marketplace)
);

CREATE INDEX IF NOT EXISTS idx_amazon_skus_asin     ON public.amazon_skus(asin);
CREATE INDEX IF NOT EXISTS idx_amazon_skus_cp       ON public.amazon_skus(contribution_profit DESC);
CREATE INDEX IF NOT EXISTS idx_amazon_skus_stockout ON public.amazon_skus(stockout_risk_score DESC);

DROP TRIGGER IF EXISTS trg_amazon_skus_updated_at ON public.amazon_skus;
CREATE TRIGGER trg_amazon_skus_updated_at
  BEFORE UPDATE ON public.amazon_skus
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ------------------------------------------------------------
-- 3. raw_reviews — review thô từ SP-API / upload thủ công
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.raw_reviews (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  asin               TEXT NOT NULL,
  reviewer_id        TEXT,
  rating             INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title              TEXT,
  body               TEXT NOT NULL,
  verified_purchase  BOOLEAN NOT NULL DEFAULT FALSE,
  source             TEXT NOT NULL DEFAULT 'sp_api'
                     CHECK (source IN ('sp_api','manual','csv')),
  reviewed_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_raw_reviews_asin ON public.raw_reviews(asin, created_at DESC);

-- ------------------------------------------------------------
-- 4. recommendations — gợi ý do decision engine sinh ra
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.recommendations (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sku_id                   UUID REFERENCES public.amazon_skus(id) ON DELETE CASCADE,
  asin                     TEXT NOT NULL,
  type                     TEXT NOT NULL
                           CHECK (type IN ('price_adjust','replenish','review_response','inventory_transfer')),
  title                    TEXT,
  rationale                TEXT,                 -- lý do / giải thích
  current_value            NUMERIC(12,2),
  proposed_value           NUMERIC(12,2),        -- giá mới, số lượng, ...
  expected_impact          NUMERIC(12,2),        -- USD/tháng ước tính
  risk_score               NUMERIC(5,2) NOT NULL DEFAULT 0
                           CHECK (risk_score BETWEEN 0 AND 100),
  -- L0 = tự động, L1 = operator duyệt, L2 = admin duyệt
  required_approval_level  TEXT NOT NULL DEFAULT 'L1'
                           CHECK (required_approval_level IN ('L0','L1','L2')),
  -- draft → pending_approval → approved → executed → rolled_back / rejected
  status                   TEXT NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft','pending_approval','approved','rejected','executed','rolled_back')),
  created_by               UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at              TIMESTAMPTZ,
  executed_at              TIMESTAMPTZ,
  rollback_reason          TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_recommendations_asin   ON public.recommendations(asin, status);
CREATE INDEX IF NOT EXISTS idx_recommendations_sku    ON public.recommendations(sku_id);
CREATE INDEX IF NOT EXISTS idx_recommendations_status ON public.recommendations(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_recommendations_risk   ON public.recommendations(risk_score DESC);

DROP TRIGGER IF EXISTS trg_recommendations_updated_at ON public.recommendations;
CREATE TRIGGER trg_recommendations_updated_at
  BEFORE UPDATE ON public.recommendations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ------------------------------------------------------------
-- 5. exceptions — hàng đợi ngoại lệ / vi phạm policy
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exceptions (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recommendation_id  UUID REFERENCES public.recommendations(id) ON DELETE CASCADE,
  asin               TEXT,
  code               TEXT NOT NULL CHECK (code IN ('P0','P1','P2','P3')),  -- mức ưu tiên
  message            TEXT NOT NULL,
  resolved           BOOLEAN NOT NULL DEFAULT FALSE,
  resolved_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_exceptions_resolved ON public.exceptions(resolved, created_at DESC);

-- ------------------------------------------------------------
-- 6. audit_log — nhật ký hành động (phục vụ compliance / rollback)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_log (
  id           BIGSERIAL PRIMARY KEY,
  actor_id     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  entity_type  TEXT NOT NULL,       -- 'recommendation' | 'sku' | ...
  entity_id    UUID,
  action       TEXT NOT NULL,       -- 'create' | 'approve' | 'execute' | 'rollback' ...
  payload      JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON public.audit_log(entity_type, entity_id, created_at DESC);

-- ============================================================
-- Row Level Security
-- ============================================================
ALTER TABLE public.profiles        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.amazon_skus     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.raw_reviews     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exceptions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log       ENABLE ROW LEVEL SECURITY;

-- Xóa policy cũ (nếu có) để script chạy lại được
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('profiles','amazon_skus','raw_reviews','recommendations','exceptions','audit_log')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
END $$;

-- ---------- profiles ----------
CREATE POLICY profiles_select_authenticated ON public.profiles
  FOR SELECT TO authenticated USING (true);
CREATE POLICY profiles_update_own ON public.profiles
  FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE POLICY profiles_admin_all ON public.profiles
  FOR ALL TO authenticated
  USING (public.current_role_in(ARRAY['admin'])) WITH CHECK (public.current_role_in(ARRAY['admin']));

-- ---------- amazon_skus ----------
-- ⚠ PILOT MODE: app hiện chưa có đăng nhập nên cho phép `anon` đọc/ghi.
--   Khi bật Supabase Auth, hãy chạy supabase/003_lock_down.sql để siết lại.
CREATE POLICY skus_pilot_anon_all ON public.amazon_skus
  FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY skus_select_authenticated ON public.amazon_skus
  FOR SELECT TO authenticated USING (true);
CREATE POLICY skus_manage_operator ON public.amazon_skus
  FOR ALL TO authenticated
  USING (public.current_role_in(ARRAY['admin','operator']))
  WITH CHECK (public.current_role_in(ARRAY['admin','operator']));

-- ---------- raw_reviews ----------
CREATE POLICY reviews_pilot_anon_select ON public.raw_reviews
  FOR SELECT TO anon USING (true);
CREATE POLICY reviews_select_authenticated ON public.raw_reviews
  FOR SELECT TO authenticated USING (true);
CREATE POLICY reviews_manage_admin ON public.raw_reviews
  FOR ALL TO authenticated
  USING (public.current_role_in(ARRAY['admin'])) WITH CHECK (public.current_role_in(ARRAY['admin']));

-- ---------- recommendations ----------
CREATE POLICY recs_pilot_anon_all ON public.recommendations
  FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY recs_select_authenticated ON public.recommendations
  FOR SELECT TO authenticated USING (true);
CREATE POLICY recs_insert_operator ON public.recommendations
  FOR INSERT TO authenticated
  WITH CHECK (public.current_role_in(ARRAY['admin','operator']));
CREATE POLICY recs_update_by_role ON public.recommendations
  FOR UPDATE TO authenticated
  USING (
    -- operator chỉ được xử lý gợi ý mức L0/L1; admin xử lý tất cả
    (required_approval_level IN ('L0','L1') AND public.current_role_in(ARRAY['operator']))
    OR public.current_role_in(ARRAY['admin'])
  );
CREATE POLICY recs_delete_admin ON public.recommendations
  FOR DELETE TO authenticated USING (public.current_role_in(ARRAY['admin']));

-- ---------- exceptions ----------
CREATE POLICY exceptions_pilot_anon_select ON public.exceptions
  FOR SELECT TO anon USING (true);
CREATE POLICY exceptions_select_authenticated ON public.exceptions
  FOR SELECT TO authenticated USING (true);
CREATE POLICY exceptions_manage_operator ON public.exceptions
  FOR ALL TO authenticated
  USING (public.current_role_in(ARRAY['admin','operator']))
  WITH CHECK (public.current_role_in(ARRAY['admin','operator']));

-- ---------- audit_log ----------
CREATE POLICY audit_select_authenticated ON public.audit_log
  FOR SELECT TO authenticated USING (true);
CREATE POLICY audit_insert_authenticated ON public.audit_log
  FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================
-- View tiện ích cho dashboard
-- ============================================================
CREATE OR REPLACE VIEW public.v_sku_overview AS
SELECT
  s.id, s.asin, s.sku, s.title, s.marketplace,
  s.current_price, s.cogs, s.contribution_profit,
  s.sales_last_30d,
  s.contribution_profit * s.sales_last_30d          AS contribution_profit_30d,
  s.inventory_qty, s.reorder_point, s.stockout_risk_score,
  CASE
    WHEN s.sales_last_30d > 0 THEN ROUND(s.inventory_qty::numeric / (s.sales_last_30d / 30.0), 1)
    ELSE NULL
  END                                              AS days_of_cover,
  (SELECT COUNT(*) FROM public.recommendations r
    WHERE r.sku_id = s.id AND r.status IN ('draft','pending_approval')) AS open_recommendations,
  s.updated_at
FROM public.amazon_skus s;

GRANT SELECT ON public.v_sku_overview TO anon, authenticated;
