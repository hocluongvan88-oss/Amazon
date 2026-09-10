-- ============================================================
-- 012 — P0‑1: Permission theo hành động (tenant‑scoped), 7 role,
--        separation of duties, delegated approval, tách
--        approval_tier (cấp duyệt) khỏi automation_level (mức tự động hoá)
-- Chạy SAU 011. Idempotent.
--
-- Roles (tenant_members.role):
--   owner · ops_lead · operator · finance · content_qa · brand_approver · viewer
-- Permission = 'domain.action' (bảng role_permissions). Kiểm tra bằng
--   has_permission(tenant, perm)  — có tính delegation còn hiệu lực.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Mở rộng role
-- ------------------------------------------------------------
ALTER TABLE public.tenant_members DROP CONSTRAINT IF EXISTS tenant_members_role_check;
ALTER TABLE public.tenant_members ADD CONSTRAINT tenant_members_role_check
  CHECK (role IN ('owner','ops_lead','operator','finance','content_qa','brand_approver','viewer'));

-- ------------------------------------------------------------
-- 2. Danh mục permission & ma trận role → permission
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.permissions (
  key         TEXT PRIMARY KEY,           -- 'domain.action'
  domain      TEXT NOT NULL,
  description TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.role_permissions (
  role           TEXT NOT NULL,
  permission_key TEXT NOT NULL REFERENCES public.permissions(key) ON DELETE CASCADE,
  PRIMARY KEY (role, permission_key)
);

INSERT INTO public.permissions (key, domain, description) VALUES
  ('dashboard.view',        'dashboard', 'Xem dashboard & báo cáo'),
  ('member.manage',         'tenant',    'Thêm/đổi vai trò thành viên'),
  ('policy.edit',           'tenant',    'Sửa Chính sách (policy_register)'),
  ('policy.override',       'tenant',    'Override policy block (bắt buộc lý do)'),
  ('delegation.grant',      'tenant',    'Uỷ quyền tạm thời permission cho người khác'),
  ('sku.write',             'data',      'Tạo/sửa SKU'),
  ('sku.delete',            'data',      'Xoá SKU'),
  ('data.import',           'data',      'Nhập dữ liệu / chạy đối soát'),
  ('cogs.write',            'finance',   'Ghi COGS / landed cost / phí'),
  ('cogs.override',         'finance',   'Owner override COGS (bắt buộc lý do)'),
  ('facts.propose',         'content',   'Đề xuất Product Facts'),
  ('facts.approve',         'content',   'Duyệt Product Facts'),
  ('content.draft',         'content',   'Tạo listing / A+ draft'),
  ('content.qa_approve',    'content',   'Duyệt compliance/QA content'),
  ('content.brand_approve', 'content',   'Duyệt cuối content (brand)'),
  ('content.publish',       'content',   'Ghi nhận publish listing / A+'),
  ('rec.create',            'decision',  'Tạo / gửi duyệt khuyến nghị'),
  ('rec.approve_l0',        'approval',  'Duyệt cấp L0'),
  ('rec.approve_l1',        'approval',  'Duyệt cấp L1 (bid/budget/giá nhỏ)'),
  ('rec.approve_l2',        'approval',  'Duyệt cấp L2 (giá lớn / PO)'),
  ('exception.resolve',     'decision',  'Xử lý exception'),
  ('action.dry_run',        'action',    'Chạy thử (dry‑run)'),
  ('action.execute',        'action',    'Thực thi canary/live (vẫn cần cấp duyệt)'),
  ('action.rollback',       'action',    'Rollback hành động'),
  ('voc.triage',            'voc',       'Triage review, mở/đóng ticket, soạn phản hồi'),
  ('voc.approve_response',  'voc',       'Duyệt phản hồi khách hàng'),
  ('report.sign',           'measure',   'Ký báo cáo pilot')
ON CONFLICT (key) DO UPDATE SET domain = EXCLUDED.domain, description = EXCLUDED.description;

-- Ma trận (xem docs/OPERATING_GOVERNANCE_v0.1.md §2)
DELETE FROM public.role_permissions;
INSERT INTO public.role_permissions (role, permission_key)
SELECT r, k FROM (VALUES
  -- viewer
  ('viewer','dashboard.view'),
  -- operator
  ('operator','dashboard.view'),('operator','sku.write'),('operator','data.import'),
  ('operator','facts.propose'),('operator','content.draft'),
  ('operator','rec.create'),('operator','rec.approve_l0'),('operator','exception.resolve'),
  ('operator','action.dry_run'),('operator','action.execute'),('operator','action.rollback'),
  ('operator','voc.triage'),
  -- ops_lead
  ('ops_lead','dashboard.view'),('ops_lead','sku.write'),('ops_lead','data.import'),
  ('ops_lead','facts.propose'),('ops_lead','facts.approve'),('ops_lead','content.draft'),('ops_lead','content.qa_approve'),
  ('ops_lead','rec.create'),('ops_lead','rec.approve_l0'),('ops_lead','rec.approve_l1'),('ops_lead','exception.resolve'),
  ('ops_lead','action.dry_run'),('ops_lead','action.execute'),('ops_lead','action.rollback'),
  ('ops_lead','voc.triage'),('ops_lead','voc.approve_response'),('ops_lead','policy.edit'),
  -- finance
  ('finance','dashboard.view'),('finance','data.import'),('finance','cogs.write'),
  -- content_qa
  ('content_qa','dashboard.view'),('content_qa','facts.propose'),('content_qa','facts.approve'),
  ('content_qa','content.draft'),('content_qa','content.qa_approve'),('content_qa','policy.override'),
  ('content_qa','voc.triage'),
  -- brand_approver (người của khách hàng)
  ('brand_approver','dashboard.view'),('brand_approver','facts.approve'),('brand_approver','content.draft'),
  ('brand_approver','content.qa_approve'),('brand_approver','content.brand_approve'),('brand_approver','content.publish'),
  ('brand_approver','policy.override'),('brand_approver','voc.approve_response')
) AS v(r, k);
-- owner: mọi permission
INSERT INTO public.role_permissions (role, permission_key) SELECT 'owner', key FROM public.permissions
ON CONFLICT DO NOTHING;

ALTER TABLE public.permissions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS perm_select ON public.permissions;
DROP POLICY IF EXISTS rp_select   ON public.role_permissions;
CREATE POLICY perm_select ON public.permissions      FOR SELECT TO authenticated USING (true);
CREATE POLICY rp_select   ON public.role_permissions FOR SELECT TO authenticated USING (true);

-- ------------------------------------------------------------
-- 3. Delegation: uỷ quyền tạm thời, có thời hạn, audit
--    (VD: brand uỷ quyền content.brand_approve cho Vexim Ops Lead 30 ngày)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.permission_delegations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  grantor_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  grantee_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  permission_key  TEXT NOT NULL REFERENCES public.permissions(key),
  reason          TEXT NOT NULL CHECK (length(trim(reason)) >= 5),
  starts_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at      TIMESTAMPTZ NOT NULL,
  revoked_at      TIMESTAMPTZ,
  revoked_by      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (expires_at > starts_at),
  CHECK (expires_at <= starts_at + interval '90 days'),
  CHECK (grantor_id <> grantee_id)
);
CREATE INDEX IF NOT EXISTS idx_delegations_grantee ON public.permission_delegations(tenant_id, grantee_id, permission_key)
  WHERE revoked_at IS NULL;

-- ------------------------------------------------------------
-- 4. Hàm kiểm tra
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_permission(t UUID, perm TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.tenant_members m
    JOIN public.role_permissions rp ON rp.role = m.role
    WHERE m.user_id = auth.uid() AND m.tenant_id = t AND rp.permission_key = perm
  ) OR EXISTS (
    SELECT 1 FROM public.permission_delegations d
    WHERE d.tenant_id = t AND d.grantee_id = auth.uid() AND d.permission_key = perm
      AND d.revoked_at IS NULL AND now() BETWEEN d.starts_at AND d.expires_at
  );
$$;

-- Quyền của user hiện tại trong tenant (cho UI)
CREATE OR REPLACE FUNCTION public.my_permissions(t UUID)
RETURNS SETOF TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT rp.permission_key FROM public.tenant_members m
  JOIN public.role_permissions rp ON rp.role = m.role
  WHERE m.user_id = auth.uid() AND m.tenant_id = t
  UNION
  SELECT d.permission_key FROM public.permission_delegations d
  WHERE d.tenant_id = t AND d.grantee_id = auth.uid()
    AND d.revoked_at IS NULL AND now() BETWEEN d.starts_at AND d.expires_at;
$$;

-- can_approve giữ chữ ký cũ, chuyển sang permission
CREATE OR REPLACE FUNCTION public.can_approve(t UUID, lvl TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN lvl = 'L2' THEN public.has_permission(t, 'rec.approve_l2')
    WHEN lvl = 'L1' THEN public.has_permission(t, 'rec.approve_l1')
    ELSE                  public.has_permission(t, 'rec.approve_l0')
  END;
$$;

-- has_role: tương thích ngược — các policy cũ dùng ARRAY['owner','operator']
-- được hiểu là "quyền ghi vận hành" → ops_lead cũng được tính là operator.
CREATE OR REPLACE FUNCTION public.has_role(t UUID, roles TEXT[])
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.tenant_members
                 WHERE user_id = auth.uid() AND tenant_id = t
                   AND (role = ANY(roles) OR (role = 'ops_lead' AND 'operator' = ANY(roles))));
$$;

GRANT EXECUTE ON FUNCTION public.has_permission(UUID, TEXT), public.my_permissions(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 5. Delegation RPC (grantor phải có permission đó + delegation.grant hoặc là owner)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grant_delegation(t UUID, grantee_email TEXT, perm TEXT, p_reason TEXT, p_days INT DEFAULT 30)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE gid UUID; did UUID;
BEGIN
  IF NOT public.has_permission(t, perm) THEN RAISE EXCEPTION 'Bạn không có quyền % để uỷ quyền', perm; END IF;
  IF NOT (public.has_permission(t, 'delegation.grant') OR perm = 'content.brand_approve') THEN
    RAISE EXCEPTION 'Bạn không được uỷ quyền permission này';
  END IF;
  IF p_days < 1 OR p_days > 90 THEN RAISE EXCEPTION 'Thời hạn uỷ quyền 1–90 ngày'; END IF;
  SELECT id INTO gid FROM auth.users WHERE lower(email) = lower(grantee_email);
  IF gid IS NULL THEN RAISE EXCEPTION 'Chưa có tài khoản %', grantee_email; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tenant_members WHERE tenant_id = t AND user_id = gid) THEN
    RAISE EXCEPTION 'Người nhận phải là thành viên của tenant';
  END IF;
  INSERT INTO public.permission_delegations (tenant_id, grantor_id, grantee_id, permission_key, reason, expires_at)
  VALUES (t, auth.uid(), gid, perm, p_reason, now() + make_interval(days => p_days)) RETURNING id INTO did;
  RETURN did;
END; $$;

CREATE OR REPLACE FUNCTION public.revoke_delegation(p_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d public.permission_delegations%ROWTYPE;
BEGIN
  SELECT * INTO d FROM public.permission_delegations WHERE id = p_id;
  IF d.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy uỷ quyền'; END IF;
  IF NOT (d.grantor_id = auth.uid() OR public.has_permission(d.tenant_id, 'member.manage')) THEN RAISE EXCEPTION 'Không đủ quyền thu hồi'; END IF;
  UPDATE public.permission_delegations SET revoked_at = now(), revoked_by = auth.uid() WHERE id = p_id AND revoked_at IS NULL;
END; $$;
GRANT EXECUTE ON FUNCTION public.grant_delegation(UUID, TEXT, TEXT, TEXT, INT), public.revoke_delegation(UUID) TO authenticated;

ALTER TABLE public.permission_delegations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS deleg_select ON public.permission_delegations;
CREATE POLICY deleg_select ON public.permission_delegations FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.my_tenant_ids()));
-- ghi chỉ qua RPC

-- add_member_by_email: dùng member.manage
CREATE OR REPLACE FUNCTION public.add_member_by_email(t UUID, member_email TEXT, member_role TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID;
BEGIN
  IF NOT public.has_permission(t, 'member.manage') THEN RAISE EXCEPTION 'Không đủ quyền quản lý thành viên'; END IF;
  SELECT id INTO uid FROM auth.users WHERE lower(email) = lower(member_email);
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Chưa có tài khoản với email %. Người dùng cần đăng nhập ít nhất một lần trước.', member_email;
  END IF;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES (t, uid, member_role)
  ON CONFLICT (tenant_id, user_id) DO UPDATE SET role = EXCLUDED.role;
END; $$;

-- ------------------------------------------------------------
-- 6. Tách approval_tier ↔ automation_level
-- ------------------------------------------------------------
-- recommendations.required_approval_level → approval_tier (cấp/phạm vi duyệt L0–L2)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='recommendations' AND column_name='required_approval_level') THEN
    ALTER TABLE public.recommendations RENAME COLUMN required_approval_level TO approval_tier;
  END IF;
END $$;
COMMENT ON COLUMN public.recommendations.approval_tier IS 'Cấp/phạm vi phê duyệt (L0 operator, L1 ops_lead, L2 owner). KHÔNG phải mức tự động hoá.';

-- actions.automation_level: mức tự động hoá thực tế của lần thực thi (L0–L5)
ALTER TABLE public.actions ADD COLUMN IF NOT EXISTS automation_level TEXT NOT NULL DEFAULT 'L3'
  CHECK (automation_level IN ('L0','L1','L2','L3','L4','L5'));
COMMENT ON COLUMN public.actions.automation_level IS 'L3 = human approve, hệ thống chuẩn bị/ghi nhận; L4 = bounded auto‑action có rollback. L5 không dùng trong MVP.';
-- policy: trần tự động hoá cho tenant (mặc định L3 — pilot L1–L3; L4 chỉ khi owner bật)
ALTER TABLE public.policy_register ADD COLUMN IF NOT EXISTS max_automation_level TEXT NOT NULL DEFAULT 'L3'
  CHECK (max_automation_level IN ('L1','L2','L3','L4'));

-- Cập nhật các trigger/function đang tham chiếu cột cũ
CREATE OR REPLACE FUNCTION public.assign_recommendation_level()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND (NEW.approval_tier IS NULL OR NEW.approval_tier = 'L1') THEN
    NEW.approval_tier := public.approval_level_for(
      NEW.tenant_id, NEW.type, COALESCE(NEW.risk_score, 0), NEW.current_value, NEW.proposed_value);
  END IF;
  RETURN NEW;
END; $$;

-- ------------------------------------------------------------
-- 7. Separation of duties trên recommendations
--    maker ≠ approver; override chỉ khi có policy.override + lý do (ghi audit)
-- ------------------------------------------------------------
ALTER TABLE public.recommendations ADD COLUMN IF NOT EXISTS sod_override_reason TEXT;

CREATE OR REPLACE FUNCTION public.guard_recommendation_transition()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid();
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
      (OLD.status = 'draft'            AND NEW.status = 'pending_approval') OR
      (OLD.status = 'pending_approval' AND NEW.status IN ('approved','rejected')) OR
      (OLD.status = 'approved'         AND NEW.status IN ('executed','rejected')) OR
      (OLD.status = 'executed'         AND NEW.status = 'rolled_back') OR
      (OLD.status IN ('rejected','rolled_back') AND NEW.status = 'draft')
    ) THEN
      RAISE EXCEPTION 'Chuyển trạng thái % → % không hợp lệ', OLD.status, NEW.status;
    END IF;

    -- Permission theo hành động
    IF uid IS NOT NULL THEN
      IF NEW.status = 'pending_approval' AND NOT public.has_permission(NEW.tenant_id, 'rec.create') THEN
        RAISE EXCEPTION 'Không đủ quyền gửi duyệt';
      END IF;
      IF NEW.status IN ('approved','rejected') AND NOT public.can_approve(NEW.tenant_id, NEW.approval_tier) THEN
        RAISE EXCEPTION 'Bạn không đủ quyền duyệt cấp %', NEW.approval_tier;
      END IF;
      IF NEW.status = 'executed' AND NOT public.has_permission(NEW.tenant_id, 'action.execute') THEN
        RAISE EXCEPTION 'Không đủ quyền thực thi';
      END IF;
      IF NEW.status = 'rolled_back' AND NOT public.has_permission(NEW.tenant_id, 'action.rollback') THEN
        RAISE EXCEPTION 'Không đủ quyền rollback';
      END IF;

      -- Separation of duties: người tạo/gửi không tự duyệt
      IF NEW.status = 'approved' AND uid IN (OLD.created_by, OLD.submitted_by) THEN
        IF COALESCE(trim(NEW.sod_override_reason), '') = '' OR NOT public.has_permission(NEW.tenant_id, 'policy.override') THEN
          RAISE EXCEPTION 'Người tạo/gửi không được tự duyệt (cần người khác duyệt, hoặc override có lý do với quyền policy.override)';
        END IF;
      END IF;
    END IF;

    IF NEW.status = 'rejected' AND COALESCE(trim(NEW.rejection_reason), '') = '' THEN
      RAISE EXCEPTION 'Cần nhập lý do từ chối';
    END IF;

    CASE NEW.status
      WHEN 'pending_approval' THEN NEW.submitted_by := uid; NEW.submitted_at := now();
      WHEN 'approved'  THEN NEW.approved_by := uid; NEW.approved_at := now();
      WHEN 'rejected'  THEN NEW.rejected_by := uid; NEW.rejected_at := now();
      WHEN 'executed'  THEN NEW.executed_by := uid; NEW.executed_at := now();
      WHEN 'draft'     THEN
        NEW.approved_by := NULL; NEW.approved_at := NULL;
        NEW.rejected_by := NULL; NEW.rejected_at := NULL; NEW.rejection_reason := NULL;
        NEW.executed_by := NULL; NEW.executed_at := NULL; NEW.rollback_reason := NULL;
        NEW.sod_override_reason := NULL;
      ELSE NULL;
    END CASE;
  END IF;
  RETURN NEW;
END; $$;

-- ------------------------------------------------------------
-- 8. RLS theo permission cho các bảng nhạy cảm (thay policy role cứng)
-- ------------------------------------------------------------
-- COGS: chỉ finance (+ owner)
DROP POLICY IF EXISTS cogs_write ON public.cogs_history;
CREATE POLICY cogs_write ON public.cogs_history FOR ALL TO authenticated
  USING (public.has_permission(tenant_id, 'cogs.write')) WITH CHECK (public.has_permission(tenant_id, 'cogs.write'));

-- policy_register: policy.edit
DROP POLICY IF EXISTS policy_update_owner ON public.policy_register;
CREATE POLICY policy_update ON public.policy_register FOR UPDATE TO authenticated
  USING (public.has_permission(tenant_id, 'policy.edit')) WITH CHECK (public.has_permission(tenant_id, 'policy.edit'));

-- tenant_members: member.manage
DROP POLICY IF EXISTS members_manage_owner ON public.tenant_members;
CREATE POLICY members_manage ON public.tenant_members FOR ALL TO authenticated
  USING (public.has_permission(tenant_id, 'member.manage')) WITH CHECK (public.has_permission(tenant_id, 'member.manage'));

-- import_jobs: data.import
DROP POLICY IF EXISTS import_insert ON public.import_jobs;
CREATE POLICY import_insert ON public.import_jobs FOR INSERT TO authenticated
  WITH CHECK (public.has_permission(tenant_id, 'data.import'));

-- sku write / delete
DROP POLICY IF EXISTS skus_write  ON public.amazon_skus;
DROP POLICY IF EXISTS skus_update ON public.amazon_skus;
DROP POLICY IF EXISTS skus_delete ON public.amazon_skus;
CREATE POLICY skus_write  ON public.amazon_skus FOR INSERT TO authenticated WITH CHECK (public.has_permission(tenant_id, 'sku.write'));
CREATE POLICY skus_update ON public.amazon_skus FOR UPDATE TO authenticated USING (public.has_permission(tenant_id, 'sku.write')) WITH CHECK (public.has_permission(tenant_id, 'sku.write'));
CREATE POLICY skus_delete ON public.amazon_skus FOR DELETE TO authenticated USING (public.has_permission(tenant_id, 'sku.delete'));

-- recommendations insert/update: rec.create (chuyển trạng thái được trigger kiểm tra chi tiết)
DROP POLICY IF EXISTS recs_insert ON public.recommendations;
DROP POLICY IF EXISTS recs_update ON public.recommendations;
CREATE POLICY recs_insert ON public.recommendations FOR INSERT TO authenticated WITH CHECK (public.has_permission(tenant_id, 'rec.create'));
CREATE POLICY recs_update ON public.recommendations FOR UPDATE TO authenticated
  USING (public.has_permission(tenant_id, 'rec.create') OR public.has_permission(tenant_id, 'rec.approve_l0'))
  WITH CHECK (public.has_permission(tenant_id, 'rec.create') OR public.has_permission(tenant_id, 'rec.approve_l0'));

-- exceptions: exception.resolve
DROP POLICY IF EXISTS exc_write ON public.exceptions;
CREATE POLICY exc_write ON public.exceptions FOR ALL TO authenticated
  USING (public.has_permission(tenant_id, 'exception.resolve')) WITH CHECK (public.has_permission(tenant_id, 'exception.resolve'));

-- VoC: voc.triage
DROP POLICY IF EXISTS voc_write ON public.voc_tickets;
DROP POLICY IF EXISTS rd_write  ON public.response_drafts;
DROP POLICY IF EXISTS rc_write  ON public.review_classifications;
CREATE POLICY voc_write ON public.voc_tickets FOR ALL TO authenticated USING (public.has_permission(tenant_id, 'voc.triage')) WITH CHECK (public.has_permission(tenant_id, 'voc.triage'));
CREATE POLICY rd_write  ON public.response_drafts FOR ALL TO authenticated USING (public.has_permission(tenant_id, 'voc.triage')) WITH CHECK (public.has_permission(tenant_id, 'voc.triage'));
CREATE POLICY rc_write  ON public.review_classifications FOR ALL TO authenticated USING (public.has_permission(tenant_id, 'voc.triage')) WITH CHECK (public.has_permission(tenant_id, 'voc.triage'));

-- pilot_reports: report.sign
DROP POLICY IF EXISTS pr_write ON public.pilot_reports;
CREATE POLICY pr_write ON public.pilot_reports FOR ALL TO authenticated USING (public.has_permission(tenant_id, 'report.sign')) WITH CHECK (public.has_permission(tenant_id, 'report.sign'));

-- ------------------------------------------------------------
-- 9. Cập nhật function tham chiếu cột cũ / role cứng
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_recommendation(p_rec UUID, p_mode TEXT DEFAULT 'dry_run')
RETURNS public.actions LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.recommendations%ROWTYPE; k public.amazon_skus%ROWTYPE; pol public.policy_register%ROWTYPE; a public.actions;
        atype TEXT; payload JSONB; key TEXT; resp JSONB; live_today INT; base NUMERIC; dry_ok BOOLEAN; chg NUMERIC;
BEGIN
  IF p_mode NOT IN ('dry_run','canary','live') THEN RAISE EXCEPTION 'mode không hợp lệ'; END IF;
  SELECT * INTO r FROM public.recommendations WHERE id = p_rec;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Không tìm thấy gợi ý'; END IF;
  SELECT * INTO pol FROM public.policy_register WHERE tenant_id = r.tenant_id;
  SELECT * INTO k FROM public.amazon_skus WHERE id = r.sku_id;

  -- quyền (action-based): dry_run = action.dry_run; canary/live = action.execute + đủ approval_tier
  IF auth.uid() IS NOT NULL THEN
    IF p_mode = 'dry_run' THEN
      IF NOT public.has_permission(r.tenant_id, 'action.dry_run') THEN RAISE EXCEPTION 'Không đủ quyền chạy thử'; END IF;
    ELSE
      IF NOT public.has_permission(r.tenant_id, 'action.execute') THEN RAISE EXCEPTION 'Không đủ quyền thực thi'; END IF;
      IF NOT public.can_approve(r.tenant_id, r.approval_tier) THEN RAISE EXCEPTION 'Cấp duyệt % cần quyền cao hơn để thực thi', r.approval_tier; END IF;
    END IF;
  END IF;
  -- trần tự động hoá: live (L4 bounded auto-action) chỉ khi chính sách cho phép L4
  IF p_mode = 'live' AND pol.max_automation_level <> 'L4' THEN
    RAISE EXCEPTION 'Chính sách giới hạn mức tự động hoá ở % — chế độ live (L4) chưa được bật', pol.max_automation_level;
  END IF;

  -- điều kiện chạy thật
  IF p_mode <> 'dry_run' THEN
    IF r.status <> 'approved' THEN RAISE EXCEPTION 'Chỉ thực thi gợi ý đã được duyệt (hiện: %)', r.status; END IF;
    IF p_mode = 'live' AND NOT pol.automation_live THEN RAISE EXCEPTION 'Chế độ live đang tắt trong Chính sách'; END IF;
    IF NOT (r.asin = ANY(pol.canary_asins)) THEN RAISE EXCEPTION 'ASIN % chưa nằm trong danh sách canary', r.asin; END IF;
    SELECT count(*) INTO live_today FROM public.actions WHERE tenant_id = r.tenant_id AND mode <> 'dry_run' AND created_at > now() - interval '24 hours' AND status IN ('succeeded','running','queued');
    IF live_today >= pol.max_live_actions_per_day THEN RAISE EXCEPTION 'Đã đạt giới hạn % lệnh/ngày', pol.max_live_actions_per_day; END IF;
    SELECT EXISTS (SELECT 1 FROM public.actions WHERE recommendation_id = r.id AND mode = 'dry_run' AND status = 'succeeded') INTO dry_ok;
    IF NOT dry_ok THEN RAISE EXCEPTION 'Cần chạy thử (dry‑run) thành công trước'; END IF;
  END IF;

  -- payload theo loại gợi ý
  CASE r.type
    WHEN 'price_adjust' THEN
      atype := 'price_update';
      IF r.proposed_value IS NULL OR k.id IS NULL THEN RAISE EXCEPTION 'Gợi ý thiếu giá đề xuất / SKU'; END IF;
      chg := abs(r.proposed_value / NULLIF(k.current_price, 0) - 1) * 100;
      IF chg > pol.price_change_max_pct THEN RAISE EXCEPTION 'Thay đổi giá % phần trăm vượt trần % phần trăm của chính sách', round(chg, 1), pol.price_change_max_pct; END IF;
      IF (r.proposed_value - k.cogs - k.fee_per_unit - r.proposed_value * k.referral_fee_pct / 100) / r.proposed_value * 100 < pol.min_margin_pct THEN
        RAISE EXCEPTION 'Giá mới làm biên dưới mức tối thiểu % phần trăm', pol.min_margin_pct; END IF;
      payload := jsonb_build_object('asin', r.asin, 'sku', k.sku, 'marketplace', k.marketplace, 'current_price', k.current_price, 'new_price', r.proposed_value, 'currency', 'USD');
    WHEN 'replenish' THEN
      atype := 'replenish_po';
      payload := jsonb_build_object('asin', r.asin, 'sku', k.sku, 'qty', r.proposed_value::int, 'supplier', k.supplier, 'lead_time_days', k.lead_time_days);
    ELSE
      atype := 'inventory_note';
      payload := jsonb_build_object('asin', r.asin, 'note', r.title);
  END CASE;
  key := md5(r.id::text || ':' || p_mode || ':' || payload::text);

  PERFORM set_config('vexim.action_ctx', 'on', true);
  -- idempotent: đã có lệnh thành công/đang chạy cùng key → trả lại
  SELECT * INTO a FROM public.actions WHERE tenant_id = r.tenant_id AND idempotency_key = key;
  IF a.id IS NOT NULL AND a.status IN ('succeeded','running','queued') THEN RETURN a; END IF;
  IF a.id IS NOT NULL THEN
    UPDATE public.actions SET status = 'running', attempt = attempt + 1, started_at = now(), error = NULL WHERE id = a.id RETURNING * INTO a;
  ELSE
    INSERT INTO public.actions (tenant_id, recommendation_id, sku_id, asin, action_type, mode, idempotency_key, payload, status, attempt, before_value, started_at, created_by, automation_level)
    VALUES (r.tenant_id, r.id, r.sku_id, r.asin, atype, p_mode, key, payload, 'running', 1, CASE WHEN atype = 'price_update' THEN k.current_price END, now(), auth.uid(), CASE WHEN p_mode = 'live' THEN 'L4' ELSE 'L3' END)
    RETURNING * INTO a;
  END IF;

  BEGIN
    resp := public._connector_internal(a);
  EXCEPTION WHEN OTHERS THEN
    resp := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  IF (resp->>'ok')::boolean THEN
    SELECT COALESCE(AVG(units), 0) INTO base FROM public.sku_daily_snapshots WHERE sku_id = r.sku_id AND date > CURRENT_DATE - 7 AND date <= CURRENT_DATE AND units IS NOT NULL;
    UPDATE public.actions SET status = 'succeeded', response = resp, finished_at = now(),
      after_value = CASE WHEN atype = 'price_update' THEN (payload->>'new_price')::numeric END,
      watch_until = CASE WHEN p_mode <> 'dry_run' THEN now() + make_interval(hours => pol.rollback_watch_hours) END,
      baseline_units_per_day = CASE WHEN p_mode <> 'dry_run' THEN base END
    WHERE id = a.id RETURNING * INTO a;
    IF p_mode <> 'dry_run' THEN
      UPDATE public.recommendations SET status = 'executed' WHERE id = r.id AND status = 'approved';
    END IF;
  ELSE
    UPDATE public.actions SET status = 'failed', response = resp, error = resp->>'error', finished_at = now() WHERE id = a.id RETURNING * INTO a;
  END IF;
  RETURN a;
END; $$;

CREATE OR REPLACE FUNCTION public.pilot_scorecard(t UUID, p_days INT DEFAULT 14)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  base public.kpi_baseline%ROWTYPE; conn RECORD; ready RECORD; auto RECORD; res JSONB;
  cur_units BIGINT; cur_rev NUMERIC; cur_cp NUMERIC; cur_days INT; base_days INT;
  recs_total INT; recs_pending INT; recs_approved INT; recs_rejected INT; recs_executed INT; recs_by_rule INT; approvals_l0 INT; approvals_l1 INT; approvals_l2 INT;
  exc_open INT; exc_overdue INT; exc_closed INT; exc_fp INT; exc_tp INT; exc_avg_hours NUMERIC;
  voc_open INT; voc_resolved INT; voc_avg_days NUMERIC; drafts_sent INT; drafts_rejected INT; policy_violations_blocked INT; cls_verified INT; cls_correct INT;
  fc_mape NUMERIC; fc_naive NUMERIC; fc_chosen INT; risk_avg NUMERIC; skus_risk_high INT;
  imp RECORD; users_active INT; audit_ops INT; audit_first TIMESTAMPTZ; audit_last TIMESTAMPTZ; days_used INT; recon_last RECORD; incidents INT;
BEGIN
  IF NOT (t IN (SELECT public.my_tenant_ids())) AND auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'Không có quyền'; END IF;
  SELECT * INTO base FROM public.kpi_baseline WHERE tenant_id = t AND is_active ORDER BY captured_at DESC LIMIT 1;
  SELECT * INTO conn FROM public.v_data_connections WHERE tenant_id = t;
  SELECT * INTO ready FROM public.v_data_readiness WHERE tenant_id = t;
  SELECT * INTO auto FROM public.v_automation_stats WHERE tenant_id = t;
  SELECT * INTO recon_last FROM public.reconciliation_checks WHERE tenant_id = t ORDER BY created_at DESC LIMIT 1;

  -- KPI hiện tại (30 ngày)
  SELECT COALESCE(SUM(units),0), COALESCE(SUM(revenue),0), COALESCE(SUM(units*contribution_profit),0), COUNT(DISTINCT date)
    INTO cur_units, cur_rev, cur_cp, cur_days
  FROM public.sku_daily_snapshots WHERE tenant_id = t AND date > CURRENT_DATE - 30 AND units IS NOT NULL;
  base_days := CASE WHEN base.id IS NOT NULL THEN GREATEST(1, base.period_end - base.period_start + 1) END;

  -- Decision loop
  SELECT COUNT(*), COUNT(*) FILTER (WHERE status='pending_approval'), COUNT(*) FILTER (WHERE approved_at IS NOT NULL), COUNT(*) FILTER (WHERE status='rejected'),
         COUNT(*) FILTER (WHERE status IN ('executed','rolled_back')), COUNT(*) FILTER (WHERE created_by IS NULL),
         COUNT(*) FILTER (WHERE approved_at IS NOT NULL AND approval_tier='L0'), COUNT(*) FILTER (WHERE approved_at IS NOT NULL AND approval_tier='L1'), COUNT(*) FILTER (WHERE approved_at IS NOT NULL AND approval_tier='L2')
    INTO recs_total, recs_pending, recs_approved, recs_rejected, recs_executed, recs_by_rule, approvals_l0, approvals_l1, approvals_l2
  FROM public.recommendations WHERE tenant_id = t;

  -- Exceptions
  SELECT COUNT(*) FILTER (WHERE NOT resolved), COUNT(*) FILTER (WHERE NOT resolved AND due_at < now() AND (snoozed_until IS NULL OR snoozed_until < now())),
         COUNT(*) FILTER (WHERE resolved), COUNT(*) FILTER (WHERE feedback='false_positive'), COUNT(*) FILTER (WHERE feedback='true_positive'),
         ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at))/3600) FILTER (WHERE resolved AND NOT auto_resolved), 1)
    INTO exc_open, exc_overdue, exc_closed, exc_fp, exc_tp, exc_avg_hours
  FROM public.exceptions WHERE tenant_id = t;

  -- VOC
  SELECT COUNT(*) FILTER (WHERE status IN ('open','investigating')), COUNT(*) FILTER (WHERE status IN ('resolved','wont_fix')),
         ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at))/86400) FILTER (WHERE resolved_at IS NOT NULL), 1)
    INTO voc_open, voc_resolved, voc_avg_days FROM public.voc_tickets WHERE tenant_id = t;
  SELECT COUNT(*) FILTER (WHERE status='sent'), COUNT(*) FILTER (WHERE status='rejected'), COUNT(*) FILTER (WHERE NOT (policy_check->>'ok')::boolean)
    INTO drafts_sent, drafts_rejected, policy_violations_blocked FROM public.response_drafts WHERE tenant_id = t;
  SELECT COUNT(*) FILTER (WHERE verified_at IS NOT NULL), COUNT(*) FILTER (WHERE verified_ok) INTO cls_verified, cls_correct FROM public.review_classifications WHERE tenant_id = t AND method <> 'human';

  -- Forecast & risk
  SELECT ROUND(SUM(avg_mape*chosen_skus)/NULLIF(SUM(chosen_skus),0),1), SUM(chosen_skus) INTO fc_mape, fc_chosen FROM public.v_forecast_accuracy WHERE tenant_id = t AND chosen_skus > 0;
  SELECT avg_mape INTO fc_naive FROM public.v_forecast_accuracy WHERE tenant_id = t AND model = 'naive7';
  SELECT ROUND(AVG(risk_score),1), COUNT(*) FILTER (WHERE risk_score >= 70) INTO risk_avg, skus_risk_high FROM public.amazon_skus WHERE tenant_id = t AND status='active';

  -- Impact tổng hợp
  SELECT COUNT(*) AS n, COUNT(*) FILTER (WHERE incremental_cp_per_day IS NOT NULL) AS measured, COUNT(*) FILTER (WHERE significant) AS sig,
         COALESCE(SUM(incremental_cp_total),0) AS total, COALESCE(SUM(ci_low*days_after),0) AS low, COALESCE(SUM(ci_high*days_after),0) AS high
    INTO imp FROM public.action_impacts(t, p_days);

  -- Operator usage & incidents
  SELECT COUNT(DISTINCT actor_id), COUNT(*), MIN(created_at), MAX(created_at), COUNT(DISTINCT created_at::date)
    INTO users_active, audit_ops, audit_first, audit_last, days_used FROM public.audit_log WHERE tenant_id = t AND actor_id IS NOT NULL;
  incidents := COALESCE(auto.uncontrolled_writes,0) + COALESCE((SELECT COUNT(*) FROM public.response_drafts WHERE tenant_id = t AND status IN ('approved','sent') AND NOT (policy_check->>'ok')::boolean),0);

  res := jsonb_build_object(
    'generated_at', now(), 'window_days', p_days,
    'baseline', CASE WHEN base.id IS NULL THEN NULL ELSE jsonb_build_object('period_start', base.period_start, 'period_end', base.period_end, 'units_per_day', round(base.units::numeric/base_days,1), 'revenue_per_day', round(base.revenue/base_days,2), 'cp_per_day', round(base.contribution_profit/base_days,2), 'cp_margin_pct', base.cp_margin_pct, 'data_readiness_pct', base.data_readiness_pct, 'skus_at_risk', base.skus_at_risk) END,
    'current', jsonb_build_object('days', cur_days, 'units_per_day', CASE WHEN cur_days>0 THEN round(cur_units::numeric/cur_days,1) END, 'revenue_per_day', CASE WHEN cur_days>0 THEN round(cur_rev/cur_days,2) END, 'cp_per_day', CASE WHEN cur_days>0 THEN round(cur_cp/cur_days,2) END, 'cp_margin_pct', CASE WHEN cur_rev>0 THEN round(cur_cp/cur_rev*100,2) END, 'data_readiness_pct', ready.readiness_pct, 'skus_risk_high', skus_risk_high, 'risk_avg', risk_avg),
    'evidence', jsonb_build_object(
      'data_reconciled', jsonb_build_object('pass', COALESCE(recon_last.passed,false) AND recon_last.created_at > now() - interval '14 days' AND COALESCE(conn.coverage_revenue_pct,0) >= 90,
        'last_recon_at', recon_last.created_at, 'last_recon_passed', recon_last.passed, 'revenue_diff_pct', recon_last.revenue_diff_pct, 'coverage_revenue_pct', conn.coverage_revenue_pct, 'last_state_snapshot', conn.last_state_snapshot, 'sales_days_30', conn.sales_days_30, 'readiness_pct', ready.readiness_pct),
      'operators_use_workflow', jsonb_build_object('pass', COALESCE(users_active,0) >= 1 AND COALESCE(recs_approved,0) + COALESCE(recs_rejected,0) >= 5 AND COALESCE(exc_closed,0) >= 5,
        'users_active', users_active, 'audit_ops', audit_ops, 'days_used', days_used, 'first_use', audit_first, 'last_use', audit_last,
        'recs_total', recs_total, 'recs_by_rule', recs_by_rule, 'recs_approved', recs_approved, 'recs_rejected', recs_rejected, 'recs_pending', recs_pending,
        'approvals_by_level', jsonb_build_object('L0', approvals_l0, 'L1', approvals_l1, 'L2', approvals_l2),
        'exceptions_closed', exc_closed, 'exceptions_open', exc_open, 'exceptions_overdue', exc_overdue, 'exception_avg_hours', exc_avg_hours,
        'exception_precision_pct', CASE WHEN COALESCE(exc_tp,0)+COALESCE(exc_fp,0) > 0 THEN round(100.0*exc_tp/(exc_tp+exc_fp)) END,
        'voc_open', voc_open, 'voc_resolved', voc_resolved, 'voc_avg_days', voc_avg_days, 'drafts_sent', drafts_sent, 'drafts_rejected', drafts_rejected,
        'classification_precision_pct', CASE WHEN cls_verified > 0 THEN round(100.0*cls_correct/cls_verified) END, 'classification_verified', cls_verified),
      'actions_create_impact', jsonb_build_object('pass', imp.measured >= 1 AND imp.total > 0,
        'actions_real', imp.n, 'actions_measured', imp.measured, 'actions_significant', imp.sig, 'incremental_cp_total', round(imp.total,2), 'ci_low', round(imp.low,2), 'ci_high', round(imp.high,2),
        'recs_executed', recs_executed, 'forecast_mape', fc_mape, 'forecast_naive_mape', fc_naive, 'forecast_beats_naive', CASE WHEN fc_mape IS NOT NULL AND fc_naive IS NOT NULL THEN fc_mape < fc_naive END),
      'zero_incidents', jsonb_build_object('pass', incidents = 0,
        'incidents', incidents, 'uncontrolled_writes', COALESCE(auto.uncontrolled_writes,0), 'policy_violations_blocked', policy_violations_blocked, 'rollbacks', COALESCE(auto.rolled_back,0), 'failed_actions', COALESCE(auto.failed,0), 'dry_runs', COALESCE(auto.dry_runs,0), 'canary_runs', COALESCE(auto.canary_runs,0), 'live_runs', COALESCE(auto.live_runs,0))
    ),
    'automation', jsonb_build_object(
      'rate_pct', CASE WHEN COALESCE(recs_approved,0) > 0 THEN round(100.0*approvals_l0/recs_approved) END,   -- % quyết định ở L0 (không cần người duyệt)
      'real_actions', COALESCE(auto.canary_runs,0)+COALESCE(auto.live_runs,0), 'rolled_back', COALESCE(auto.rolled_back,0),
      'operator_minutes_saved_est', COALESCE(recs_by_rule,0)*15 + COALESCE(exc_closed,0)*10 + COALESCE(auto.dry_runs,0)*5)   -- ước lượng: 15’ / gợi ý tự sinh, 10’ / ngoại lệ, 5’ / dry‑run
  );
  RETURN res;
END; $$;

-- response_drafts: duyệt cần voc.approve_response; SoD nghiêm
CREATE OR REPLACE FUNCTION public.response_draft_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid();
BEGIN
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' AND NEW.created_by IS NULL THEN NEW.created_by := uid; END IF;
  IF TG_OP = 'INSERT' OR NEW.body IS DISTINCT FROM OLD.body THEN
    NEW.policy_check := public.check_response_policy(NEW.tenant_id, NEW.body);
    IF TG_OP = 'UPDATE' AND OLD.status IN ('approved','sent') THEN RAISE EXCEPTION 'Không sửa nội dung đã duyệt/đã gửi'; END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status IN ('pending_approval','approved','sent') AND NOT (NEW.policy_check->>'ok')::boolean THEN
      RAISE EXCEPTION 'Nháp vi phạm chính sách phản hồi: %', NEW.policy_check->'violations';
    END IF;
    IF NEW.status = 'approved' THEN
      IF uid IS NOT NULL AND NOT public.has_permission(NEW.tenant_id, 'voc.approve_response') THEN RAISE EXCEPTION 'Không đủ quyền duyệt phản hồi (voc.approve_response)'; END IF;
      -- SoD nghiêm: người duyệt ≠ người soạn (bỏ ngoại lệ tenant 1 thành viên)
      IF uid IS NOT NULL AND uid = NEW.created_by THEN RAISE EXCEPTION 'Người duyệt phải khác người soạn'; END IF;
      NEW.approved_by := uid; NEW.approved_at := now();
    END IF;
    IF NEW.status = 'rejected' AND coalesce(trim(NEW.rejected_reason), '') = '' THEN RAISE EXCEPTION 'Từ chối phải có lý do'; END IF;
    IF NEW.status = 'sent' THEN
      IF OLD.status <> 'approved' THEN RAISE EXCEPTION 'Chỉ đánh dấu đã gửi sau khi duyệt'; END IF;
      NEW.sent_at := now();
    END IF;
    IF NEW.status = 'draft' THEN NEW.approved_by := NULL; NEW.approved_at := NULL; NEW.rejected_reason := NULL; END IF;
  END IF;
  RETURN NEW;
END; $$;

-- run_reconciliation: finance cũng được chạy đối soát (data.import)
CREATE OR REPLACE FUNCTION public.run_reconciliation(t UUID, p_start DATE, p_end DATE, p_sc_revenue NUMERIC, p_sc_units INTEGER, p_note TEXT DEFAULT NULL)
RETURNS public.reconciliation_checks LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sys_r NUMERIC; sys_u INTEGER; tol NUMERIC; rdiff NUMERIC; udiff NUMERIC; rec public.reconciliation_checks;
BEGIN
  IF NOT public.has_permission(t, 'data.import') THEN RAISE EXCEPTION 'Không đủ quyền chạy đối soát (data.import)'; END IF;
  SELECT COALESCE(SUM(revenue),0), COALESCE(SUM(units),0) INTO sys_r, sys_u
    FROM public.sku_daily_snapshots WHERE tenant_id = t AND date BETWEEN p_start AND p_end;
  SELECT revenue_tolerance_pct INTO tol FROM public.policy_register WHERE tenant_id = t;
  tol := COALESCE(tol, 2);
  rdiff := CASE WHEN p_sc_revenue > 0 THEN ROUND(100 * (sys_r - p_sc_revenue) / p_sc_revenue, 2) END;
  udiff := CASE WHEN p_sc_units > 0 THEN ROUND(100 * (sys_u - p_sc_units)::numeric / p_sc_units, 2) END;
  INSERT INTO public.reconciliation_checks
    (tenant_id, period_start, period_end, sc_revenue, sc_units, sys_revenue, sys_units, revenue_diff_pct, units_diff_pct, tolerance_pct, passed, note, created_by)
  VALUES (t, p_start, p_end, p_sc_revenue, p_sc_units, sys_r, sys_u, rdiff, udiff, tol,
          COALESCE(abs(rdiff) <= tol, FALSE) AND COALESCE(abs(udiff) <= tol, FALSE), p_note, auth.uid())
  RETURNING * INTO rec;
  RETURN rec;
END; $$;

-- ------------------------------------------------------------
-- 10. Audit cho delegation + members
-- ------------------------------------------------------------
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['permission_delegations','tenant_members']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.write_audit_log()', t, t);
  END LOOP;
END $$;

-- tenant_members không có cột id → write_audit_log dùng rec.id; bọc lại an toàn
CREATE OR REPLACE FUNCTION public.write_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rec        RECORD := COALESCE(NEW, OLD);
  act        TEXT;
  before_j   JSONB := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
  after_j    JSONB := CASE WHEN TG_OP IN ('UPDATE','INSERT') THEN to_jsonb(NEW) END;
  email      TEXT  := COALESCE(auth.jwt() ->> 'email', NULL);
  rec_j      JSONB := to_jsonb(rec);
  ent_id     UUID  := COALESCE((rec_j->>'id')::uuid, (rec_j->>'user_id')::uuid);
BEGIN
  act := lower(TG_OP);
  -- dùng jsonb để không phụ thuộc cột tồn tại trên từng bảng
  IF TG_TABLE_NAME = 'recommendations' AND TG_OP = 'UPDATE' AND (after_j->>'status') IS DISTINCT FROM (before_j->>'status') THEN
    act := 'status:' || (after_j->>'status');
    IF after_j->>'status' = 'approved' AND (after_j->>'sod_override_reason') IS NOT NULL THEN act := 'status:approved:sod_override'; END IF;
  ELSIF TG_TABLE_NAME = 'exceptions' AND TG_OP = 'UPDATE' AND (after_j->>'resolved') IS DISTINCT FROM (before_j->>'resolved') THEN
    act := CASE WHEN (after_j->>'resolved')::boolean THEN 'resolve' ELSE 'reopen' END;
  ELSIF TG_TABLE_NAME = 'permission_delegations' THEN
    act := CASE WHEN TG_OP = 'INSERT' THEN 'delegation:grant' WHEN (rec_j->>'revoked_at') IS NOT NULL THEN 'delegation:revoke' ELSE act END;
  ELSIF TG_TABLE_NAME = 'tenant_members' THEN
    act := 'member:' || act;
  END IF;

  INSERT INTO public.audit_log (tenant_id, actor_id, actor_email, entity_type, entity_id, action, before, after, payload)
  VALUES (
    (rec_j->>'tenant_id')::uuid, auth.uid(), email, TG_TABLE_NAME, ent_id, act,
    before_j, after_j,
    CASE WHEN TG_OP = 'UPDATE' THEN
      (SELECT jsonb_object_agg(k, after_j -> k) FROM jsonb_object_keys(after_j) k
        WHERE after_j -> k IS DISTINCT FROM before_j -> k AND k <> 'updated_at')
    END
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ------------------------------------------------------------
-- 11. View ma trận quyền (cho UI Cài đặt → Thành viên)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_role_matrix WITH (security_invoker = true) AS
SELECT p.key, p.domain, p.description,
       array_agg(rp.role ORDER BY rp.role) AS roles
FROM public.permissions p
LEFT JOIN public.role_permissions rp ON rp.permission_key = p.key
GROUP BY p.key, p.domain, p.description;

-- Kiểm tra nhanh
-- SELECT * FROM public.v_role_matrix ORDER BY domain, key;
