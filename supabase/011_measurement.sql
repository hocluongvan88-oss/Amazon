-- ============================================================
-- 011 — Đo lường & quyết định: incremental CP (diff‑in‑diff + CI), scorecard pilot, báo cáo  (Tuần 12‑14)
-- Chạy SAU 010. Idempotent.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tác động của từng lệnh thật: trước/sau N ngày, đối chứng = các ASIN active không có lệnh thật trong cùng cửa sổ
--    incremental CP/ngày = (after_t − before_t) − (after_c − before_c) tính theo CP/ngày (đối chứng chuẩn hoá theo tỷ lệ)
--    CI 95% ≈ ±1.96 × SE, SE từ độ lệch chuẩn CP ngày của ASIN tác động (trước & sau) – xấp xỉ, đủ cho quyết định pilot
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.action_impact(p_action UUID, p_days INT DEFAULT 14)
RETURNS TABLE (
  action_id UUID, asin TEXT, mode TEXT, executed_at TIMESTAMPTZ, days_before INT, days_after INT,
  cp_before_per_day NUMERIC, cp_after_per_day NUMERIC, units_before_per_day NUMERIC, units_after_per_day NUMERIC,
  control_change_pct NUMERIC, incremental_cp_per_day NUMERIC, ci_low NUMERIC, ci_high NUMERIC, incremental_cp_total NUMERIC, significant BOOLEAN, note TEXT
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.actions%ROWTYPE; d0 DATE; t RECORD; c RECORD; se NUMERIC; ctrl_ratio NUMERIC; expected_after NUMERIC; inc NUMERIC;
BEGIN
  SELECT * INTO a FROM public.actions WHERE id = p_action;
  IF a.id IS NULL OR a.mode = 'dry_run' OR a.finished_at IS NULL THEN RETURN; END IF;
  d0 := a.finished_at::date;

  SELECT COUNT(*) FILTER (WHERE s.date < d0) AS nb, COUNT(*) FILTER (WHERE s.date > d0) AS na,
         AVG(s.units * s.contribution_profit) FILTER (WHERE s.date < d0) AS cpb, AVG(s.units * s.contribution_profit) FILTER (WHERE s.date > d0) AS cpa,
         AVG(s.units) FILTER (WHERE s.date < d0) AS ub, AVG(s.units) FILTER (WHERE s.date > d0) AS ua,
         STDDEV_SAMP(s.units * s.contribution_profit) FILTER (WHERE s.date < d0) AS sdb, STDDEV_SAMP(s.units * s.contribution_profit) FILTER (WHERE s.date > d0) AS sda
    INTO t
  FROM public.sku_daily_snapshots s
  WHERE s.sku_id = a.sku_id AND s.units IS NOT NULL AND s.contribution_profit IS NOT NULL
    AND s.date BETWEEN d0 - p_days AND d0 + p_days AND s.date <> d0;

  -- đối chứng: ASIN active cùng tenant, không có lệnh thật trong [d0-p_days, d0+p_days]
  SELECT AVG(x.cp) FILTER (WHERE x.date < d0) AS cpb, AVG(x.cp) FILTER (WHERE x.date > d0) AS cpa, COUNT(DISTINCT x.sku_id) AS n
    INTO c
  FROM (
    SELECT s.sku_id, s.date, s.units * s.contribution_profit AS cp
    FROM public.sku_daily_snapshots s
    JOIN public.amazon_skus k ON k.id = s.sku_id AND k.status = 'active'
    WHERE s.tenant_id = a.tenant_id AND s.sku_id <> a.sku_id AND s.units IS NOT NULL AND s.contribution_profit IS NOT NULL
      AND s.date BETWEEN d0 - p_days AND d0 + p_days AND s.date <> d0
      AND NOT EXISTS (SELECT 1 FROM public.actions b WHERE b.sku_id = s.sku_id AND b.mode <> 'dry_run' AND b.status IN ('succeeded','rolled_back')
                      AND b.finished_at::date BETWEEN d0 - p_days AND d0 + p_days)
  ) x;

  action_id := a.id; asin := a.asin; mode := a.mode; executed_at := a.finished_at;
  days_before := COALESCE(t.nb, 0); days_after := COALESCE(t.na, 0);
  cp_before_per_day := round(t.cpb, 2); cp_after_per_day := round(t.cpa, 2);
  units_before_per_day := round(t.ub, 2); units_after_per_day := round(t.ua, 2);

  IF COALESCE(t.nb, 0) < 3 OR COALESCE(t.na, 0) < 3 THEN
    note := format('Chưa đủ dữ liệu (%s ngày trước, %s ngày sau; cần ≥ 3)', COALESCE(t.nb, 0), COALESCE(t.na, 0));
    RETURN NEXT; RETURN;
  END IF;

  IF c.n >= 2 AND c.cpb IS NOT NULL AND c.cpb <> 0 THEN
    ctrl_ratio := c.cpa / c.cpb;
    control_change_pct := round((ctrl_ratio - 1) * 100, 1);
    note := format('Đối chứng: %s ASIN không tác động, CP/ngày thay đổi %s%%', c.n, control_change_pct);
  ELSE
    ctrl_ratio := 1; control_change_pct := NULL;
    note := 'Không có nhóm đối chứng đủ lớn – so sánh trước/sau thuần';
  END IF;
  expected_after := t.cpb * ctrl_ratio;
  inc := t.cpa - expected_after;
  se := sqrt(COALESCE(t.sdb, 0)^2 / t.nb + COALESCE(t.sda, 0)^2 / t.na);
  incremental_cp_per_day := round(inc, 2);
  ci_low := round(inc - 1.96 * se, 2); ci_high := round(inc + 1.96 * se, 2);
  incremental_cp_total := round(inc * t.na, 2);
  significant := (ci_low > 0) OR (ci_high < 0);
  RETURN NEXT;
END; $$;

CREATE OR REPLACE FUNCTION public.action_impacts(t UUID, p_days INT DEFAULT 14)
RETURNS TABLE (
  action_id UUID, asin TEXT, mode TEXT, executed_at TIMESTAMPTZ, days_before INT, days_after INT,
  cp_before_per_day NUMERIC, cp_after_per_day NUMERIC, units_before_per_day NUMERIC, units_after_per_day NUMERIC,
  control_change_pct NUMERIC, incremental_cp_per_day NUMERIC, ci_low NUMERIC, ci_high NUMERIC, incremental_cp_total NUMERIC, significant BOOLEAN, note TEXT
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.* FROM public.actions a, LATERAL public.action_impact(a.id, p_days) i
  WHERE a.tenant_id = t AND a.mode <> 'dry_run' AND a.status IN ('succeeded','rolled_back') AND a.tenant_id IN (SELECT public.my_tenant_ids())
  ORDER BY a.finished_at DESC;
$$;
GRANT EXECUTE ON FUNCTION public.action_impact(UUID, INT), public.action_impacts(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 2. Scorecard pilot: một hàng JSON gom mọi gate + KPI
-- ------------------------------------------------------------
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
         COUNT(*) FILTER (WHERE approved_at IS NOT NULL AND required_approval_level='L0'), COUNT(*) FILTER (WHERE approved_at IS NOT NULL AND required_approval_level='L1'), COUNT(*) FILTER (WHERE approved_at IS NOT NULL AND required_approval_level='L2')
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
GRANT EXECUTE ON FUNCTION public.pilot_scorecard(UUID, INT) TO authenticated;

-- ------------------------------------------------------------
-- 3. Lưu báo cáo đã xuất (bằng chứng có dấu thời gian)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pilot_reports (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  scorecard   JSONB NOT NULL,
  markdown    TEXT NOT NULL,
  decision    TEXT CHECK (decision IN ('scale','extend','stop')),
  decision_note TEXT,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.pilot_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pr_select ON public.pilot_reports; DROP POLICY IF EXISTS pr_write ON public.pilot_reports;
CREATE POLICY pr_select ON public.pilot_reports FOR SELECT TO authenticated USING (tenant_id IN (SELECT public.my_tenant_ids()));
CREATE POLICY pr_write  ON public.pilot_reports FOR ALL TO authenticated USING (public.has_role(tenant_id, ARRAY['owner','operator'])) WITH CHECK (public.has_role(tenant_id, ARRAY['owner','operator']));
