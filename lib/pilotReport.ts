/** Sinh Markdown báo cáo pilot từ scorecard (pilot_scorecard rpc). */
export type Scorecard = {
  generated_at: string; window_days: number;
  baseline: null | { period_start: string; period_end: string; units_per_day: number; revenue_per_day: number; cp_per_day: number; cp_margin_pct: number | null; data_readiness_pct: number | null; skus_at_risk: number | null };
  current: { days: number; units_per_day: number | null; revenue_per_day: number | null; cp_per_day: number | null; cp_margin_pct: number | null; data_readiness_pct: number | null; skus_risk_high: number; risk_avg: number | null };
  evidence: {
    data_reconciled: { pass: boolean; last_recon_at: string | null; last_recon_passed: boolean | null; revenue_diff_pct: number | null; coverage_revenue_pct: number | null; last_state_snapshot: string | null; sales_days_30: number | null; readiness_pct: number | null };
    operators_use_workflow: { pass: boolean; users_active: number; audit_ops: number; days_used: number; first_use: string | null; last_use: string | null; recs_total: number; recs_by_rule: number; recs_approved: number; recs_rejected: number; recs_pending: number; approvals_by_level: { L0: number; L1: number; L2: number }; exceptions_closed: number; exceptions_open: number; exceptions_overdue: number; exception_avg_hours: number | null; exception_precision_pct: number | null; voc_open: number; voc_resolved: number; voc_avg_days: number | null; drafts_sent: number; drafts_rejected: number; classification_precision_pct: number | null; classification_verified: number };
    actions_create_impact: { pass: boolean; actions_real: number; actions_measured: number; actions_significant: number; incremental_cp_total: number; ci_low: number; ci_high: number; recs_executed: number; forecast_mape: number | null; forecast_naive_mape: number | null; forecast_beats_naive: boolean | null };
    zero_incidents: { pass: boolean; incidents: number; uncontrolled_writes: number; policy_violations_blocked: number; rollbacks: number; failed_actions: number; dry_runs: number; canary_runs: number; live_runs: number };
  };
  automation: { rate_pct: number | null; real_actions: number; rolled_back: number; operator_minutes_saved_est: number };
};
export type Impact = { action_id: string; asin: string; mode: string; executed_at: string; days_before: number; days_after: number; cp_before_per_day: number | null; cp_after_per_day: number | null; units_before_per_day: number | null; units_after_per_day: number | null; control_change_pct: number | null; incremental_cp_per_day: number | null; ci_low: number | null; ci_high: number | null; incremental_cp_total: number | null; significant: boolean | null; note: string | null };

const f = (n: number | null | undefined, d = 0) => (n == null ? '—' : Number(n).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }));
const usd = (n: number | null | undefined) => (n == null ? '—' : `$${f(n, 2)}`);
const dt = (s: string | null | undefined) => (s ? new Date(s).toLocaleDateString('vi-VN') : '—');
const pf = (b: boolean) => (b ? '✅ ĐẠT' : '❌ CHƯA ĐẠT');
const delta = (a: number | null | undefined, b: number | null | undefined) => (a == null || b == null || b === 0 ? '' : ` (${a >= b ? '+' : ''}${((a / b - 1) * 100).toFixed(1)}%)`);

export function buildPilotReport(tenantName: string, sc: Scorecard, impacts: Impact[], decision?: string, note?: string): string {
  const e = sc.evidence; const b = sc.baseline; const c = sc.current;
  const passCount = [e.data_reconciled.pass, e.operators_use_workflow.pass, e.actions_create_impact.pass, e.zero_incidents.pass].filter(Boolean).length;
  const L: string[] = [];
  L.push(`# Báo cáo pilot – ${tenantName}`);
  L.push(`Tạo lúc ${new Date(sc.generated_at).toLocaleString('vi-VN')} · cửa sổ đo tác động ±${sc.window_days} ngày · **${passCount}/4 bằng chứng đạt**`);
  if (decision) L.push(`\n**Quyết định:** ${{ scale: 'MỞ RỘNG', extend: 'GIA HẠN PILOT', stop: 'DỪNG' }[decision] ?? decision}${note ? ` – ${note}` : ''}`);
  L.push('\n## 1. North Star – Lợi nhuận đóng góp (CP)');
  L.push('| Chỉ số | Baseline | Hiện tại (30 ngày) |'); L.push('|---|---:|---:|');
  L.push(`| Kỳ | ${b ? `${dt(b.period_start)} → ${dt(b.period_end)}` : 'chưa chốt'} | ${c.days} ngày dữ liệu |`);
  L.push(`| CP / ngày | ${usd(b?.cp_per_day)} | ${usd(c.cp_per_day)}${delta(c.cp_per_day, b?.cp_per_day)} |`);
  L.push(`| Doanh thu / ngày | ${usd(b?.revenue_per_day)} | ${usd(c.revenue_per_day)}${delta(c.revenue_per_day, b?.revenue_per_day)} |`);
  L.push(`| Units / ngày | ${f(b?.units_per_day, 1)} | ${f(c.units_per_day, 1)}${delta(c.units_per_day, b?.units_per_day)} |`);
  L.push(`| Biên CP | ${f(b?.cp_margin_pct, 1)}% | ${f(c.cp_margin_pct, 1)}% |`);
  L.push(`| Sẵn sàng dữ liệu | ${f(b?.data_readiness_pct, 0)}% | ${f(c.data_readiness_pct, 0)}% |`);
  L.push(`| ASIN rủi ro cao (≥70) | ${f(b?.skus_at_risk)} | ${f(c.skus_risk_high)} |`);

  L.push(`\n## 2. Bằng chứng 1 – Dữ liệu đã đối soát: ${pf(e.data_reconciled.pass)}`);
  L.push(`- Đối soát gần nhất: ${dt(e.data_reconciled.last_recon_at)} – ${e.data_reconciled.last_recon_passed ? 'đạt' : 'không đạt / chưa có'} (lệch doanh thu ${f(e.data_reconciled.revenue_diff_pct, 2)}%)`);
  L.push(`- Độ phủ doanh thu có dữ liệu ngày: ${f(e.data_reconciled.coverage_revenue_pct, 0)}% (gate ≥ 90%) · ${e.data_reconciled.sales_days_30 ?? 0}/30 ngày có dữ liệu bán · snapshot gần nhất ${dt(e.data_reconciled.last_state_snapshot)}`);
  L.push(`- Sẵn sàng dữ liệu (COGS/phí/lead time): ${f(e.data_reconciled.readiness_pct, 0)}%`);

  const o = e.operators_use_workflow;
  L.push(`\n## 3. Bằng chứng 2 – Operator dùng workflow: ${pf(o.pass)}`);
  L.push(`- ${o.users_active} người dùng hoạt động · ${f(o.audit_ops)} thao tác ghi nhận trong nhật ký · ${o.days_used} ngày sử dụng (${dt(o.first_use)} → ${dt(o.last_use)})`);
  L.push(`- Gợi ý: ${o.recs_total} tổng (${o.recs_by_rule} do rule sinh) · ${o.recs_approved} duyệt · ${o.recs_rejected} từ chối · ${o.recs_pending} chờ · phân cấp duyệt L0/L1/L2 = ${o.approvals_by_level.L0}/${o.approvals_by_level.L1}/${o.approvals_by_level.L2}`);
  L.push(`- Ngoại lệ: ${o.exceptions_closed} đã đóng · ${o.exceptions_open} mở (${o.exceptions_overdue} quá hạn SLA) · thời gian xử lý TB ${f(o.exception_avg_hours, 1)} giờ · precision cảnh báo ${f(o.exception_precision_pct)}%`);
  L.push(`- VOC: ${o.voc_resolved} ticket đã xử lý / ${o.voc_open} mở · TB ${f(o.voc_avg_days, 1)} ngày · ${o.drafts_sent} tin liên hệ KH đã gửi (${o.drafts_rejected} bị từ chối khi duyệt) · precision phân loại ${f(o.classification_precision_pct)}% trên ${o.classification_verified} mẫu QA`);

  const a = e.actions_create_impact;
  L.push(`\n## 4. Bằng chứng 3 – Hành động tạo tác động: ${pf(a.pass)}`);
  L.push(`- ${a.actions_real} lệnh thật (canary/live), ${a.actions_measured} đã đủ dữ liệu đo, ${a.actions_significant} có ý nghĩa thống kê (CI 95% không chứa 0)`);
  L.push(`- **Incremental CP tổng: ${usd(a.incremental_cp_total)}** (CI 95%: ${usd(a.ci_low)} → ${usd(a.ci_high)}), phương pháp trước/sau có đối chứng (ASIN không tác động)`);
  L.push(`- Forecast: MAPE mô hình chọn ${f(a.forecast_mape, 1)}% vs naive ${f(a.forecast_naive_mape, 1)}% → ${a.forecast_beats_naive == null ? 'chưa đủ dữ liệu' : a.forecast_beats_naive ? 'tốt hơn naive' : 'CHƯA tốt hơn naive'}`);
  if (impacts.length) {
    L.push('\n| ASIN | Chế độ | Ngày | CP/ngày trước → sau | Đối chứng | Incremental/ngày | CI 95% | Tổng | Ý nghĩa |'); L.push('|---|---|---|---|---:|---:|---|---:|---|');
    impacts.forEach((i) => L.push(`| ${i.asin} | ${i.mode} | ${dt(i.executed_at)} | ${usd(i.cp_before_per_day)} → ${usd(i.cp_after_per_day)} | ${i.control_change_pct == null ? '—' : `${i.control_change_pct}%`} | ${usd(i.incremental_cp_per_day)} | ${i.ci_low == null ? '—' : `${usd(i.ci_low)} … ${usd(i.ci_high)}`} | ${usd(i.incremental_cp_total)} | ${i.incremental_cp_per_day == null ? i.note ?? '' : i.significant ? 'có' : 'chưa'} |`));
  }

  const z = e.zero_incidents;
  L.push(`\n## 5. Bằng chứng 4 – 0 sự cố: ${pf(z.pass)}`);
  L.push(`- Sự cố: **${z.incidents}** (ghi ngoài kiểm soát ${z.uncontrolled_writes} · tin vi phạm chính sách lọt qua duyệt 0)`);
  L.push(`- Tin liên hệ KH bị hệ thống chặn vì từ ngữ vi phạm: ${z.policy_violations_blocked} · hoàn tác: ${z.rollbacks} · lệnh lỗi: ${z.failed_actions}`);
  L.push(`- Mức tự động hoá đã đi qua: ${z.dry_runs} chạy thử → ${z.canary_runs} canary → ${z.live_runs} live`);

  L.push('\n## 6. Tự động hoá & thời gian operator');
  L.push(`- Tỷ lệ quyết định ở L0 (không cần người duyệt): ${f(sc.automation.rate_pct)}% · lệnh thật ${sc.automation.real_actions} · hoàn tác ${sc.automation.rolled_back}`);
  L.push(`- Thời gian operator tiết kiệm ước tính: ~${f(sc.automation.operator_minutes_saved_est / 60, 1)} giờ (15’/gợi ý tự sinh, 10’/ngoại lệ xử lý, 5’/chạy thử)`);
  L.push('\n---\n*Sinh tự động bởi Vexim Amazon Managed Operations. Mọi số liệu truy vết được trong nhật ký hệ thống.*');
  return L.join('\n');
}
