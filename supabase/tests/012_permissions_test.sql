-- ============================================================
-- Test 012 — chạy trong SQL Editor (role postgres) SAU khi đã chạy 012.
-- Mô phỏng user bằng cách set request.jwt.claims; toàn bộ trong 1 transaction, ROLLBACK cuối.
-- Kết quả mong đợi: mọi dòng NOTICE 'PASS …'; nếu có 'FAIL …' → dừng lại.
-- ============================================================
-- Một khối DO duy nhất (SQL Editor/pooler không giữ TEMP giữa các câu lệnh).
-- Kết thúc bằng RAISE EXCEPTION để ROLLBACK toàn bộ — thông báo "lỗi" cuối cùng chính là bảng kết quả.
DO $$
DECLARE t UUID; sku UUID; rec UUID;
  u_owner UUID := gen_random_uuid(); u_lead UUID := gen_random_uuid(); u_op UUID := gen_random_uuid();
  u_fin UUID := gen_random_uuid(); u_qa UUID := gen_random_uuid(); u_brand UUID := gen_random_uuid(); u_view UUID := gen_random_uuid();
  u UUID;
  _r RECORD; _fails INT := 0; _out TEXT := '';
BEGIN
  CREATE TEMP TABLE _t (name TEXT, ok BOOLEAN) ON COMMIT DROP;
  EXECUTE $f$CREATE OR REPLACE FUNCTION pg_temp.as_user(u UUID) RETURNS VOID LANGUAGE sql AS $b$
    SELECT set_config('request.jwt.claims', json_build_object('sub', u::text, 'email', u::text || '@test.local', 'role', 'authenticated')::text, true);
  $b$$f$;
  EXECUTE $f$CREATE OR REPLACE FUNCTION pg_temp.expect_error(name TEXT, sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$
  BEGIN BEGIN EXECUTE sql; INSERT INTO _t VALUES (name, false); EXCEPTION WHEN OTHERS THEN INSERT INTO _t VALUES (name, true); END; END $b$$f$;
  EXECUTE $f$CREATE OR REPLACE FUNCTION pg_temp.expect_ok(name TEXT, sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$
  BEGIN BEGIN EXECUTE sql; INSERT INTO _t VALUES (name, true); EXCEPTION WHEN OTHERS THEN INSERT INTO _t VALUES (name || ' (' || SQLERRM || ')', false); END; END $b$$f$;

  FOREACH u IN ARRAY ARRAY[u_owner,u_lead,u_op,u_fin,u_qa,u_brand,u_view] LOOP
    INSERT INTO auth.users (id, email, instance_id, aud, role, encrypted_password, created_at, updated_at)
    VALUES (u, u::text || '@test.local', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), now());
  END LOOP;
  INSERT INTO public.tenants (slug, name) VALUES ('t012', 'Test 012') RETURNING id INTO t;
  INSERT INTO public.tenant_members (tenant_id, user_id, role) VALUES
    (t, u_owner, 'owner'), (t, u_lead, 'ops_lead'), (t, u_op, 'operator'), (t, u_fin, 'finance'),
    (t, u_qa, 'content_qa'), (t, u_brand, 'brand_approver'), (t, u_view, 'viewer');
  INSERT INTO public.amazon_skus (tenant_id, asin, sku, title, marketplace, current_price, cogs, fee_per_unit, referral_fee_pct)
  VALUES (t, 'B0TEST0012', 'T-012', 'Test SKU', 'US', 30, 10, 5, 15) RETURNING id INTO sku;

  -- 1. viewer không có quyền ghi
  PERFORM pg_temp.as_user(u_view);
  INSERT INTO _t SELECT 'viewer: no rec.create', NOT public.has_permission(t, 'rec.create');
  INSERT INTO _t SELECT 'viewer: dashboard.view', public.has_permission(t, 'dashboard.view');

  -- 2. finance ghi COGS được; operator không
  PERFORM pg_temp.as_user(u_fin);
  INSERT INTO _t SELECT 'finance: cogs.write', public.has_permission(t, 'cogs.write');
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO _t SELECT 'operator: no cogs.write', NOT public.has_permission(t, 'cogs.write');

  -- 3. approval tiers
  PERFORM pg_temp.as_user(u_op);
  INSERT INTO _t SELECT 'operator: approve L0', public.can_approve(t, 'L0');
  INSERT INTO _t SELECT 'operator: NOT approve L1', NOT public.can_approve(t, 'L1');
  PERFORM pg_temp.as_user(u_lead);
  INSERT INTO _t SELECT 'ops_lead: approve L1', public.can_approve(t, 'L1');
  INSERT INTO _t SELECT 'ops_lead: NOT approve L2', NOT public.can_approve(t, 'L2');
  PERFORM pg_temp.as_user(u_owner);
  INSERT INTO _t SELECT 'owner: approve L2', public.can_approve(t, 'L2');

  -- 4. content chain
  PERFORM pg_temp.as_user(u_qa);
  INSERT INTO _t SELECT 'content_qa: qa_approve', public.has_permission(t, 'content.qa_approve');
  INSERT INTO _t SELECT 'content_qa: NOT publish', NOT public.has_permission(t, 'content.publish');
  PERFORM pg_temp.as_user(u_brand);
  INSERT INTO _t SELECT 'brand: brand_approve + publish', public.has_permission(t, 'content.brand_approve') AND public.has_permission(t, 'content.publish');
  INSERT INTO _t SELECT 'brand: NOT cogs.write', NOT public.has_permission(t, 'cogs.write');

  -- 5. Separation of duties trên recommendations (tier L1 → ops_lead duyệt)
  PERFORM pg_temp.as_user(u_lead);
  INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, current_value, proposed_value, risk_score, approval_tier, status)
  VALUES (t, sku, 'B0TEST0012', 'price_adjust', 'SoD test', 30, 30.5, 30, 'L1', 'draft') RETURNING id INTO rec;
  UPDATE public.recommendations SET status = 'pending_approval' WHERE id = rec;
  -- lead tự duyệt → phải lỗi
  PERFORM pg_temp.expect_error('SoD: maker cannot self-approve', format('UPDATE public.recommendations SET status = ''approved'' WHERE id = %L', rec));
  -- operator không đủ tier L1 → lỗi
  PERFORM pg_temp.as_user(u_op);
  PERFORM pg_temp.expect_error('tier: operator cannot approve L1', format('UPDATE public.recommendations SET status = ''approved'' WHERE id = %L', rec));
  -- owner (khác maker) duyệt → ok
  PERFORM pg_temp.as_user(u_owner);
  PERFORM pg_temp.expect_ok('other approver ok', format('UPDATE public.recommendations SET status = ''approved'' WHERE id = %L', rec));

  -- 6. SoD override: owner tạo → tự duyệt không lý do → lỗi; có lý do + policy.override → ok, audit ghi sod_override
  PERFORM pg_temp.as_user(u_owner);
  INSERT INTO public.recommendations (tenant_id, sku_id, asin, type, title, current_value, proposed_value, risk_score, approval_tier, status)
  VALUES (t, sku, 'B0TEST0012', 'price_adjust', 'SoD override', 30, 30.2, 10, 'L0', 'draft') RETURNING id INTO rec;
  UPDATE public.recommendations SET status = 'pending_approval' WHERE id = rec;
  PERFORM pg_temp.expect_error('SoD override without reason fails', format('UPDATE public.recommendations SET status = ''approved'' WHERE id = %L', rec));
  PERFORM pg_temp.expect_ok('SoD override with reason ok', format('UPDATE public.recommendations SET status = ''approved'', sod_override_reason = ''Chỉ có 1 người trực ca'' WHERE id = %L', rec));
  INSERT INTO _t SELECT 'audit: sod_override logged', EXISTS (SELECT 1 FROM public.audit_log WHERE entity_id = rec AND action = 'status:approved:sod_override');

  -- 7. Delegation: brand uỷ quyền content.brand_approve cho lead 7 ngày; hết hạn/thu hồi mất quyền
  PERFORM pg_temp.as_user(u_brand);
  PERFORM public.grant_delegation(t, u_lead::text || '@test.local', 'content.brand_approve', 'Brand đi công tác 1 tuần', 7);
  PERFORM pg_temp.as_user(u_lead);
  INSERT INTO _t SELECT 'delegation: lead has brand_approve', public.has_permission(t, 'content.brand_approve');
  PERFORM pg_temp.as_user(u_brand);
  PERFORM public.revoke_delegation((SELECT id FROM public.permission_delegations WHERE tenant_id = t AND grantee_id = u_lead LIMIT 1));
  PERFORM pg_temp.as_user(u_lead);
  INSERT INTO _t SELECT 'delegation: revoked → no brand_approve', NOT public.has_permission(t, 'content.brand_approve');
  INSERT INTO _t SELECT 'audit: delegation logged', EXISTS (SELECT 1 FROM public.audit_log WHERE tenant_id = t AND action IN ('delegation:grant','delegation:revoke'));
  -- operator không thể uỷ quyền thứ mình không có
  PERFORM pg_temp.as_user(u_op);
  PERFORM pg_temp.expect_error('delegation: cannot grant perm you lack', format('SELECT public.grant_delegation(%L, %L, ''rec.approve_l2'', ''thử'', 5)', t, u_lead::text || '@test.local'));
  -- delegation > 90 ngày bị chặn
  PERFORM pg_temp.as_user(u_owner);
  PERFORM pg_temp.expect_error('delegation: >90 days rejected', format('SELECT public.grant_delegation(%L, %L, ''rec.approve_l2'', ''quá dài'', 120)', t, u_lead::text || '@test.local'));

  -- 8. Tenant-scoped: user của tenant khác không có quyền
  PERFORM pg_temp.as_user(gen_random_uuid());
  INSERT INTO _t SELECT 'tenant-scoped: outsider has nothing', NOT public.has_permission(t, 'dashboard.view');

  -- 9. approval_tier vs automation_level tách biệt
  INSERT INTO _t SELECT 'schema: recommendations.approval_tier exists', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='recommendations' AND column_name='approval_tier');
  INSERT INTO _t SELECT 'schema: no required_approval_level', NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='recommendations' AND column_name='required_approval_level');
  INSERT INTO _t SELECT 'schema: actions.automation_level exists', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='actions' AND column_name='automation_level');
  INSERT INTO _t SELECT 'policy: max_automation_level default L3', (SELECT max_automation_level = 'L3' FROM public.policy_register WHERE tenant_id = t);

  FOR _r IN SELECT * FROM _t LOOP
    _out := _out || E'\n' || CASE WHEN _r.ok THEN 'PASS ' ELSE 'FAIL ' END || _r.name;
    IF NOT _r.ok THEN _fails := _fails + 1; END IF;
  END LOOP;
  RAISE EXCEPTION E'=== KẾT QUẢ TEST (đã rollback, đây KHÔNG phải lỗi) — % test, % FAIL ===%', (SELECT count(*) FROM _t), _fails, _out;
END $$;
