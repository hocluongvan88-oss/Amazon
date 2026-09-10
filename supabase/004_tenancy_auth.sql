-- ============================================================
-- 004 — Multi-tenant + Auth + Audit  (Sprint 0)
-- Chạy SAU 001 (+002 nếu có seed). File này ĐÃ BAO GỒM nội dung
-- 003_lock_down.sql (gỡ quyền anon) nên không cần chạy 003 riêng.
-- Idempotent: chạy lại được.
-- ============================================================

-- ------------------------------------------------------------
-- 1. tenants + tenant_members
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tenants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  marketplace TEXT NOT NULL DEFAULT 'US',
  settings    JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS trg_tenants_updated_at ON public.tenants;
CREATE TRIGGER trg_tenants_updated_at BEFORE UPDATE ON public.tenants
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Role theo TENANT (thay cho profiles.role toàn cục):
--   owner    : chủ brand / Vexim admin của tenant – mọi quyền, duyệt L2
--   operator : vận hành – tạo gợi ý, duyệt L0/L1
--   viewer   : chỉ xem
CREATE TABLE IF NOT EXISTS public.tenant_members (
  tenant_id  UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role       TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('owner','operator','viewer')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_tenant_members_user ON public.tenant_members(user_id);

-- Tenant mặc định cho dữ liệu pilot đã có
INSERT INTO public.tenants (slug, name) VALUES ('vexim', 'Vexim (pilot)')
ON CONFLICT (slug) DO NOTHING;

-- ------------------------------------------------------------
-- 2. Thêm tenant_id vào mọi bảng nghiệp vụ, gán về tenant 'vexim'
-- ------------------------------------------------------------
DO $$
DECLARE
  t TEXT;
  default_tenant UUID := (SELECT id FROM public.tenants WHERE slug = 'vexim');
BEGIN
  FOREACH t IN ARRAY ARRAY['amazon_skus','raw_reviews','recommendations','exceptions','audit_log']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE', t);
    EXECUTE format('UPDATE public.%I SET tenant_id = $1 WHERE tenant_id IS NULL', t) USING default_tenant;
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN tenant_id SET NOT NULL', t);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_tenant ON public.%I(tenant_id)', t, t);
  END LOOP;
END $$;

-- unique ASIN theo tenant thay vì toàn cục
ALTER TABLE public.amazon_skus DROP CONSTRAINT IF EXISTS amazon_skus_asin_marketplace_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_amazon_skus_tenant_asin ON public.amazon_skus(tenant_id, asin, marketplace);

-- Cột phục vụ approval
ALTER TABLE public.recommendations
  ADD COLUMN IF NOT EXISTS rejected_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS rejected_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
  ADD COLUMN IF NOT EXISTS executed_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submitted_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submitted_at     TIMESTAMPTZ;

-- audit_log: thêm tenant + before/after
ALTER TABLE public.audit_log
  ADD COLUMN IF NOT EXISTS actor_email TEXT,
  ADD COLUMN IF NOT EXISTS before      JSONB,
  ADD COLUMN IF NOT EXISTS after       JSONB;

-- ------------------------------------------------------------
-- 3. Helper functions (SECURITY DEFINER để tránh đệ quy RLS)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.my_tenant_ids()
RETURNS SETOF UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT tenant_id FROM public.tenant_members WHERE user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.my_role_in(t UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT role FROM public.tenant_members WHERE user_id = auth.uid() AND tenant_id = t;
$$;

CREATE OR REPLACE FUNCTION public.has_role(t UUID, roles TEXT[])
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.tenant_members
                 WHERE user_id = auth.uid() AND tenant_id = t AND role = ANY(roles));
$$;

-- Cấp duyệt tối thiểu theo role
--   L0 : operator, owner   (auto / xác nhận nhanh)
--   L1 : operator, owner
--   L2 : owner
CREATE OR REPLACE FUNCTION public.can_approve(t UUID, lvl TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN lvl = 'L2' THEN public.has_role(t, ARRAY['owner'])
    ELSE public.has_role(t, ARRAY['owner','operator'])
  END;
$$;

GRANT EXECUTE ON FUNCTION public.my_tenant_ids(), public.my_role_in(UUID),
  public.has_role(UUID, TEXT[]), public.can_approve(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 4. Trigger kiểm soát chuyển trạng thái recommendation + ghi actor
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_recommendation_transition()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid();
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    -- Chuyển hợp lệ
    IF NOT (
      (OLD.status = 'draft'            AND NEW.status = 'pending_approval') OR
      (OLD.status = 'pending_approval' AND NEW.status IN ('approved','rejected')) OR
      (OLD.status = 'approved'         AND NEW.status IN ('executed','rejected')) OR
      (OLD.status = 'executed'         AND NEW.status = 'rolled_back') OR
      (OLD.status IN ('rejected','rolled_back') AND NEW.status = 'draft')
    ) THEN
      RAISE EXCEPTION 'Chuyển trạng thái % → % không hợp lệ', OLD.status, NEW.status;
    END IF;

    -- Quyền theo cấp duyệt
    IF NEW.status IN ('approved','rejected','executed','rolled_back')
       AND NOT public.can_approve(NEW.tenant_id, NEW.required_approval_level) THEN
      RAISE EXCEPTION 'Bạn không đủ quyền xử lý gợi ý cấp %', NEW.required_approval_level;
    END IF;
    IF NEW.status = 'rejected' AND COALESCE(trim(NEW.rejection_reason), '') = '' THEN
      RAISE EXCEPTION 'Cần nhập lý do từ chối';
    END IF;

    -- Ghi actor / thời điểm
    CASE NEW.status
      WHEN 'pending_approval' THEN NEW.submitted_by := uid; NEW.submitted_at := now();
      WHEN 'approved'  THEN NEW.approved_by := uid; NEW.approved_at := now();
      WHEN 'rejected'  THEN NEW.rejected_by := uid; NEW.rejected_at := now();
      WHEN 'executed'  THEN NEW.executed_by := uid; NEW.executed_at := now();
      WHEN 'draft'     THEN
        NEW.approved_by := NULL; NEW.approved_at := NULL;
        NEW.rejected_by := NULL; NEW.rejected_at := NULL; NEW.rejection_reason := NULL;
        NEW.executed_by := NULL; NEW.executed_at := NULL; NEW.rollback_reason := NULL;
      ELSE NULL;
    END CASE;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recommendations_guard ON public.recommendations;
CREATE TRIGGER trg_recommendations_guard
  BEFORE UPDATE ON public.recommendations
  FOR EACH ROW EXECUTE FUNCTION public.guard_recommendation_transition();

-- created_by mặc định = user hiện tại
CREATE OR REPLACE FUNCTION public.set_created_by()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.created_by IS NULL THEN NEW.created_by := auth.uid(); END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_recommendations_created_by ON public.recommendations;
CREATE TRIGGER trg_recommendations_created_by
  BEFORE INSERT ON public.recommendations
  FOR EACH ROW EXECUTE FUNCTION public.set_created_by();

-- exceptions: ghi resolved_by
CREATE OR REPLACE FUNCTION public.set_exception_resolver()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.resolved AND NOT OLD.resolved THEN
    NEW.resolved_by := auth.uid(); NEW.resolved_at := now();
  ELSIF NOT NEW.resolved AND OLD.resolved THEN
    NEW.resolved_by := NULL; NEW.resolved_at := NULL;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_exceptions_resolver ON public.exceptions;
CREATE TRIGGER trg_exceptions_resolver
  BEFORE UPDATE ON public.exceptions
  FOR EACH ROW EXECUTE FUNCTION public.set_exception_resolver();

-- ------------------------------------------------------------
-- 5. Audit log tự động
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.write_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rec        RECORD := COALESCE(NEW, OLD);
  act        TEXT;
  before_j   JSONB := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
  after_j    JSONB := CASE WHEN TG_OP IN ('UPDATE','INSERT') THEN to_jsonb(NEW) END;
  email      TEXT  := COALESCE(auth.jwt() ->> 'email', NULL);
BEGIN
  act := lower(TG_OP);
  IF TG_TABLE_NAME = 'recommendations' AND TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    act := 'status:' || NEW.status;
  ELSIF TG_TABLE_NAME = 'exceptions' AND TG_OP = 'UPDATE' AND NEW.resolved IS DISTINCT FROM OLD.resolved THEN
    act := CASE WHEN NEW.resolved THEN 'resolve' ELSE 'reopen' END;
  END IF;

  INSERT INTO public.audit_log (tenant_id, actor_id, actor_email, entity_type, entity_id, action, before, after, payload)
  VALUES (
    rec.tenant_id, auth.uid(), email, TG_TABLE_NAME, rec.id, act,
    before_j, after_j,
    CASE WHEN TG_OP = 'UPDATE' THEN
      (SELECT jsonb_object_agg(k, after_j -> k) FROM jsonb_object_keys(after_j) k
        WHERE after_j -> k IS DISTINCT FROM before_j -> k AND k <> 'updated_at')
    END
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['amazon_skus','recommendations','exceptions']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()', t, t);
  END LOOP;
END $$;

-- ------------------------------------------------------------
-- 6. RLS theo tenant (thay toàn bộ policy cũ, gỡ anon)
-- ------------------------------------------------------------
ALTER TABLE public.tenants        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_members ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies
           WHERE schemaname = 'public'
             AND tablename IN ('tenants','tenant_members','amazon_skus','raw_reviews',
                               'recommendations','exceptions','audit_log')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
END $$;

-- tenants
CREATE POLICY tenants_select ON public.tenants FOR SELECT TO authenticated
  USING (id IN (SELECT public.my_tenant_ids()));
CREATE POLICY tenants_update_owner ON public.tenants FOR UPDATE TO authenticated
  USING (public.has_role(id, ARRAY['owner'])) WITH CHECK (public.has_role(id, ARRAY['owner']));

-- tenant_members
CREATE POLICY members_select ON public.tenant_members FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY members_manage_owner ON public.tenant_members FOR ALL TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner']));

-- amazon_skus
CREATE POLICY skus_select ON public.amazon_skus FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY skus_write ON public.amazon_skus FOR INSERT TO authenticated
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY skus_update ON public.amazon_skus FOR UPDATE TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner','operator']))
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY skus_delete ON public.amazon_skus FOR DELETE TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner']));

-- raw_reviews
CREATE POLICY reviews_select ON public.raw_reviews FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY reviews_write ON public.raw_reviews FOR ALL TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner','operator']))
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));

-- recommendations (quyền chuyển trạng thái được kiểm tra chi tiết trong trigger)
CREATE POLICY recs_select ON public.recommendations FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY recs_insert ON public.recommendations FOR INSERT TO authenticated
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY recs_update ON public.recommendations FOR UPDATE TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner','operator']))
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
CREATE POLICY recs_delete ON public.recommendations FOR DELETE TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner']));

-- exceptions
CREATE POLICY exc_select ON public.exceptions FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY exc_write ON public.exceptions FOR ALL TO authenticated
  USING (public.has_role(tenant_id, ARRAY['owner','operator']))
  WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));

-- audit_log: chỉ đọc; ghi qua trigger SECURITY DEFINER
CREATE POLICY audit_select ON public.audit_log FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));

-- Gỡ quyền anon (nội dung 003)
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE SELECT ON public.v_sku_overview FROM anon;

-- View v_sku_overview: thêm tenant_id
CREATE OR REPLACE VIEW public.v_sku_overview WITH (security_invoker = true) AS
SELECT
  s.id, s.tenant_id, s.asin, s.sku, s.title, s.marketplace,
  s.current_price, s.cogs, s.contribution_profit, s.sales_last_30d,
  s.contribution_profit * s.sales_last_30d AS contribution_profit_30d,
  s.inventory_qty, s.reorder_point, s.stockout_risk_score,
  CASE WHEN s.sales_last_30d > 0 THEN ROUND(s.inventory_qty::numeric / (s.sales_last_30d / 30.0), 1) END AS days_of_cover,
  (SELECT COUNT(*) FROM public.recommendations r
    WHERE r.sku_id = s.id AND r.status IN ('draft','pending_approval')) AS open_recommendations,
  s.updated_at
FROM public.amazon_skus s;
GRANT SELECT ON public.v_sku_overview TO authenticated;

-- ------------------------------------------------------------
-- 7. Tiện ích: thêm thành viên theo email (owner gọi từ UI/SQL)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_member_by_email(t UUID, member_email TEXT, member_role TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID;
BEGIN
  IF NOT public.has_role(t, ARRAY['owner']) THEN
    RAISE EXCEPTION 'Chỉ owner mới được thêm thành viên';
  END IF;
  SELECT id INTO uid FROM auth.users WHERE lower(email) = lower(member_email);
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Chưa có tài khoản với email %. Người dùng cần đăng nhập ít nhất một lần trước.', member_email;
  END IF;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, uid, member_role)
  ON CONFLICT (tenant_id, user_id) DO UPDATE SET role = EXCLUDED.role;
END; $$;
GRANT EXECUTE ON FUNCTION public.add_member_by_email(UUID, TEXT, TEXT) TO authenticated;

-- ============================================================
-- BƯỚC CUỐI (bắt buộc, làm thủ công 1 lần):
-- Đăng nhập app bằng email của bạn 1 lần (để auth.users có bản ghi), rồi chạy:
--
--   INSERT INTO public.tenant_members (tenant_id, user_id, role)
--   SELECT t.id, u.id, 'owner'
--   FROM public.tenants t, auth.users u
--   WHERE t.slug = 'vexim' AND lower(u.email) = lower('you@example.com')
--   ON CONFLICT (tenant_id, user_id) DO UPDATE SET role = 'owner';
--
-- Sau đó các thành viên khác thêm qua trang Cài đặt → Thành viên.
-- ============================================================
