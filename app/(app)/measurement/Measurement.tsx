'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, Spinner, ErrorBox, btn, input } from '@/components/ui';
import { usd, num } from '@/lib/format';
import { buildPilotReport, type Scorecard, type Impact } from '@/lib/pilotReport';
import MeasurementLedger from '@/components/MeasurementLedger';

type Report = { id: string; title: string; decision: string | null; decision_note: string | null; created_at: string; markdown: string };

export default function Measurement() {
  const { tenant, canWrite } = useTenant();
  const [sc, setSc] = React.useState<Scorecard | null>(null);
  const [impacts, setImpacts] = React.useState<Impact[]>([]);
  const [reports, setReports] = React.useState<Report[]>([]);
  const [days, setDays] = React.useState(14);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [decision, setDecision] = React.useState<'scale' | 'extend' | 'stop' | ''>('');
  const [note, setNote] = React.useState('');
  const [preview, setPreview] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState(false);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    setLoading(true);
    const [s, i, r] = await Promise.all([
      supabase.rpc('pilot_scorecard', { t: tenant.id, p_days: days }),
      supabase.rpc('action_impacts', { t: tenant.id, p_days: days }),
      supabase.from('pilot_reports').select('id,title,decision,decision_note,created_at,markdown').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(10),
    ]);
    if (s.error) setError(s.error.message); else setSc(s.data as Scorecard);
    setImpacts(((i.data ?? []) as Impact[]).map((x) => Object.fromEntries(Object.entries(x).map(([k, v]) => [k, typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v) && !['asin', 'mode', 'note', 'executed_at', 'action_id'].includes(k) ? Number(v) : v])) as Impact));
    setReports((r.data ?? []) as Report[]);
    setLoading(false);
  }, [tenant, days]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch
    void load();
  }, [load]);

  if (loading) return <Spinner />;
  if (error || !sc) return <ErrorBox message={error ?? 'Không tải được scorecard'} />;

  const e = sc.evidence;
  const evid = [
    { key: 'data_reconciled', n: 1, title: 'Dữ liệu đã đối soát', pass: e.data_reconciled.pass, lines: [`Đối soát: ${e.data_reconciled.last_recon_passed ? 'đạt' : 'chưa/không đạt'} (${e.data_reconciled.last_recon_at ? new Date(e.data_reconciled.last_recon_at).toLocaleDateString('vi-VN') : '—'})`, `Độ phủ doanh thu ${num(e.data_reconciled.coverage_revenue_pct)}% (≥90)`, `${e.data_reconciled.sales_days_30 ?? 0}/30 ngày có dữ liệu bán`, `Sẵn sàng dữ liệu ${num(e.data_reconciled.readiness_pct)}%`] },
    { key: 'ops', n: 2, title: 'Operator dùng workflow', pass: e.operators_use_workflow.pass, lines: [`${e.operators_use_workflow.users_active} người dùng · ${num(e.operators_use_workflow.audit_ops)} thao tác · ${e.operators_use_workflow.days_used} ngày`, `${e.operators_use_workflow.recs_approved} duyệt / ${e.operators_use_workflow.recs_rejected} từ chối (gate ≥5)`, `${e.operators_use_workflow.exceptions_closed} ngoại lệ đã đóng (gate ≥5) · precision ${e.operators_use_workflow.exception_precision_pct ?? '—'}%`, `VOC ${e.operators_use_workflow.voc_resolved} xử lý · ${e.operators_use_workflow.drafts_sent} tin đã gửi`] },
    { key: 'impact', n: 3, title: 'Hành động tạo tác động', pass: e.actions_create_impact.pass, lines: [`${e.actions_create_impact.actions_real} lệnh thật · ${e.actions_create_impact.actions_measured} đo được · ${e.actions_create_impact.actions_significant} có ý nghĩa`, `Incremental CP ${usd(e.actions_create_impact.incremental_cp_total, 0)}`, `CI 95%: ${usd(e.actions_create_impact.ci_low, 0)} → ${usd(e.actions_create_impact.ci_high, 0)}`, `Forecast MAPE ${e.actions_create_impact.forecast_mape ?? '—'}% vs naive ${e.actions_create_impact.forecast_naive_mape ?? '—'}%`] },
    { key: 'zero', n: 4, title: '0 sự cố', pass: e.zero_incidents.pass, lines: [`Sự cố: ${e.zero_incidents.incidents}`, `Ghi ngoài kiểm soát: ${e.zero_incidents.uncontrolled_writes}`, `Tin vi phạm bị chặn: ${e.zero_incidents.policy_violations_blocked} · hoàn tác: ${e.zero_incidents.rollbacks}`, `${e.zero_incidents.dry_runs} thử → ${e.zero_incidents.canary_runs} canary → ${e.zero_incidents.live_runs} live`] },
  ];
  const passCount = evid.filter((x) => x.pass).length;
  const b = sc.baseline, c = sc.current;
  const md = () => buildPilotReport(tenant?.name ?? 'Brand', sc, impacts, decision || undefined, note || undefined);

  async function saveReport() {
    if (!tenant) return; setBusy(true);
    const markdown = md();
    const title = `Báo cáo pilot ${new Date().toLocaleDateString('vi-VN')} – ${passCount}/4`;
    const { error: er } = await supabase.from('pilot_reports').insert({ tenant_id: tenant.id, title, scorecard: sc, markdown, decision: decision || null, decision_note: note || null });
    setBusy(false); if (er) setError(er.message); else { setPreview(markdown); load(); }
  }
  function download(text: string, name: string) {
    const blob = new Blob([text], { type: 'text/markdown;charset=utf-8' }); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; a.click(); URL.revokeObjectURL(a.href);
  }

  return (
    <>
      {/* Verdict */}
      <Card className={`mb-4 p-5 border-2 ${passCount === 4 ? 'border-emerald-300 bg-emerald-50/40' : passCount >= 2 ? 'border-amber-300 bg-amber-50/40' : 'border-red-300 bg-red-50/40'}`}>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="text-xs uppercase tracking-wide text-gray-500">Kết luận pilot</p>
            <p className="text-2xl font-bold text-gray-900">{passCount}/4 bằng chứng đạt · {passCount === 4 ? 'Đủ điều kiện mở rộng' : passCount >= 2 ? 'Nên gia hạn pilot & bổ sung bằng chứng còn thiếu' : 'Chưa đủ – tập trung vào dữ liệu & workflow'}</p>
          </div>
          <div className="flex items-center gap-2 text-sm">
            <span className="text-gray-500">Cửa sổ đo tác động</span>
            {[7, 14, 28].map((d) => <button key={d} onClick={() => setDays(d)} className={`px-2.5 py-1 rounded-lg border ${days === d ? 'bg-gray-900 text-white border-gray-900' : 'bg-white border-gray-200'}`}>±{d}d</button>)}
          </div>
        </div>
      </Card>

      {/* 4 evidence */}
      <div className="grid md:grid-cols-2 xl:grid-cols-4 gap-3 mb-4">
        {evid.map((x) => (
          <Card key={x.key} className={`p-4 border-t-4 ${x.pass ? 'border-t-emerald-500' : 'border-t-red-400'}`}>
            <div className="flex items-center justify-between"><p className="text-xs text-gray-500">Bằng chứng {x.n}</p><Badge className={x.pass ? 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' : 'bg-red-50 text-red-700 ring-red-600/20'}>{x.pass ? 'Đạt' : 'Chưa'}</Badge></div>
            <p className="font-semibold text-gray-900 mt-1">{x.title}</p>
            <ul className="mt-2 space-y-0.5 text-xs text-gray-600">{x.lines.map((l, i) => <li key={i}>• {l}</li>)}</ul>
          </Card>
        ))}
      </div>

      <div className="grid lg:grid-cols-3 gap-4 mb-4">
        {/* North star */}
        <Card className="lg:col-span-2">
          <CardHeader title="North Star – Lợi nhuận đóng góp: baseline vs hiện tại" subtitle={b ? `Baseline ${new Date(b.period_start).toLocaleDateString('vi-VN')} → ${new Date(b.period_end).toLocaleDateString('vi-VN')} · hiện tại ${c.days} ngày gần nhất` : 'Chưa chốt baseline – vào Tổng quan / Nhập dữ liệu để chốt KPI baseline'} />
          <table className="w-full text-sm">
            <thead className="text-xs uppercase text-gray-500 bg-gray-50"><tr><th className="px-4 py-2 text-left">Chỉ số</th><th className="px-2 py-2 text-right">Baseline</th><th className="px-2 py-2 text-right">Hiện tại</th><th className="px-4 py-2 text-right">Δ</th></tr></thead>
            <tbody className="divide-y divide-gray-100">
              {([['CP / ngày', b?.cp_per_day, c.cp_per_day, 'usd'], ['Doanh thu / ngày', b?.revenue_per_day, c.revenue_per_day, 'usd'], ['Units / ngày', b?.units_per_day, c.units_per_day, 'n1'], ['Biên CP %', b?.cp_margin_pct, c.cp_margin_pct, 'pct'], ['Sẵn sàng dữ liệu %', b?.data_readiness_pct, c.data_readiness_pct, 'pct'], ['ASIN rủi ro cao', b?.skus_at_risk, c.skus_risk_high, 'n']] as [string, number | null | undefined, number | null | undefined, string][]).map(([l, x, y, k]) => {
                const fmt = (v: number | null | undefined) => v == null ? '—' : k === 'usd' ? usd(v, 0) : k === 'pct' ? `${Number(v).toFixed(1)}%` : k === 'n1' ? num(v, 1) : num(v);
                const d = x != null && y != null && Number(x) !== 0 ? (Number(y) / Number(x) - 1) * 100 : null; const good = l.includes('rủi ro') ? (d ?? 0) <= 0 : (d ?? 0) >= 0;
                return <tr key={l}><td className="px-4 py-2">{l}</td><td className="px-2 py-2 text-right tabular-nums text-gray-500">{fmt(x)}</td><td className="px-2 py-2 text-right tabular-nums font-medium">{fmt(y)}</td><td className={`px-4 py-2 text-right tabular-nums ${d == null ? 'text-gray-400' : good ? 'text-emerald-700' : 'text-red-600'}`}>{d == null ? '—' : `${d >= 0 ? '+' : ''}${d.toFixed(1)}%`}</td></tr>;
              })}
            </tbody>
          </table>
        </Card>
        <Card>
          <CardHeader title="Tự động hoá & thời gian" />
          <dl className="p-4 space-y-3 text-sm">
            <Row l="Tỷ lệ quyết định L0 (không cần người duyệt)" v={sc.automation.rate_pct != null ? `${sc.automation.rate_pct}%` : '—'} />
            <Row l="Lệnh thật (canary + live)" v={String(sc.automation.real_actions)} />
            <Row l="Hoàn tác" v={String(sc.automation.rolled_back)} />
            <Row l="Ngoại lệ mở / quá hạn" v={`${e.operators_use_workflow.exceptions_open} / ${e.operators_use_workflow.exceptions_overdue}`} />
            <Row l="Backlog gợi ý chờ duyệt" v={String(e.operators_use_workflow.recs_pending)} />
            <Row l="Thời gian operator tiết kiệm (ước tính)" v={`~${(sc.automation.operator_minutes_saved_est / 60).toFixed(1)} giờ`} />
          </dl>
          <p className="px-4 pb-4 text-xs text-gray-500">Ước tính 15’/gợi ý tự sinh · 10’/ngoại lệ xử lý · 5’/chạy thử.</p>
        </Card>
      </div>

      {/* Impacts */}
      <Card className="mb-4">
        <CardHeader title="Incremental CP theo từng lệnh" subtitle="Trước/sau ±N ngày, hiệu chỉnh theo nhóm đối chứng (ASIN không có lệnh trong cùng cửa sổ). CI 95% xấp xỉ từ độ lệch chuẩn CP ngày." />
        {impacts.length === 0 ? <p className="p-5 text-sm text-gray-500">Chưa có lệnh canary/live nào. Thực thi từ trang Gợi ý để bắt đầu đo.</p> : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-xs uppercase text-gray-500 bg-gray-50"><tr><th className="px-4 py-2 text-left">ASIN</th><th className="px-2 py-2 text-left">Chế độ</th><th className="px-2 py-2 text-right">Ngày</th><th className="px-2 py-2 text-right">CP/ngày trước → sau</th><th className="px-2 py-2 text-right">Đối chứng</th><th className="px-2 py-2 text-right">Incremental/ngày</th><th className="px-2 py-2 text-right">CI 95%</th><th className="px-2 py-2 text-right">Tổng</th><th className="px-4 py-2 text-left">Ghi chú</th></tr></thead>
              <tbody className="divide-y divide-gray-100">
                {impacts.map((i) => (
                  <tr key={i.action_id}>
                    <td className="px-4 py-2 font-mono text-xs">{i.asin}</td><td className="px-2 py-2">{i.mode}</td><td className="px-2 py-2 text-right text-xs">{new Date(i.executed_at).toLocaleDateString('vi-VN')}</td>
                    <td className="px-2 py-2 text-right tabular-nums">{usd(i.cp_before_per_day)} → {usd(i.cp_after_per_day)}</td>
                    <td className="px-2 py-2 text-right tabular-nums text-gray-500">{i.control_change_pct != null ? `${i.control_change_pct}%` : '—'}</td>
                    <td className={`px-2 py-2 text-right tabular-nums font-semibold ${i.incremental_cp_per_day == null ? 'text-gray-400' : i.incremental_cp_per_day >= 0 ? 'text-emerald-700' : 'text-red-600'}`}>{usd(i.incremental_cp_per_day)}</td>
                    <td className="px-2 py-2 text-right tabular-nums text-xs">{i.ci_low != null ? `${usd(i.ci_low)} … ${usd(i.ci_high)}` : '—'}</td>
                    <td className="px-2 py-2 text-right tabular-nums">{usd(i.incremental_cp_total, 0)}</td>
                    <td className="px-4 py-2 text-xs text-gray-500">{i.incremental_cp_per_day != null && (i.significant ? <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-600/20">có ý nghĩa</Badge> : <Badge className="bg-gray-100 text-gray-600 ring-gray-500/20">chưa rõ</Badge>)} {i.note}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <MeasurementLedger tenantId={tenant?.id} canWrite={canWrite} days={days} />

      {/* Report */}
      <Card>
        <CardHeader title="Báo cáo pilot" subtitle="Xuất Markdown với 4 bằng chứng, lưu kèm scorecard có dấu thời gian." />
        <div className="p-5 space-y-3">
          {canWrite && (
            <div className="flex flex-wrap items-end gap-3">
              <div><label className="block text-xs font-medium text-gray-700 mb-1">Quyết định</label>
                <select value={decision} onChange={(e) => setDecision(e.target.value as typeof decision)} className={`${input} w-48`}><option value="">— chưa quyết —</option><option value="scale">Mở rộng</option><option value="extend">Gia hạn pilot</option><option value="stop">Dừng</option></select></div>
              <div className="flex-1 min-w-[240px]"><label className="block text-xs font-medium text-gray-700 mb-1">Ghi chú quyết định</label><input value={note} onChange={(e) => setNote(e.target.value)} className={input} placeholder="Ví dụ: mở rộng thêm 20 ASIN, giữ canary 4 tuần" /></div>
              <button className={btn.secondary} onClick={() => setPreview(md())}>Xem trước</button>
              <button className={btn.primary} disabled={busy} onClick={saveReport}>{busy ? '…' : 'Lưu & xuất báo cáo'}</button>
            </div>
          )}
          {preview && (
            <div>
              <div className="flex gap-2 mb-2"><button className={btn.secondary} onClick={() => download(preview, `pilot-report-${new Date().toISOString().slice(0, 10)}.md`)}>Tải .md</button><button className={btn.secondary} onClick={() => navigator.clipboard?.writeText(preview)}>Sao chép</button><button className={btn.ghost} onClick={() => setPreview(null)}>Đóng</button></div>
              <pre className="whitespace-pre-wrap text-xs bg-gray-50 border border-gray-200 rounded-lg p-4 max-h-[480px] overflow-auto">{preview}</pre>
            </div>
          )}
          {reports.length > 0 && (
            <div>
              <p className="text-xs font-medium text-gray-700 mb-1">Đã lưu</p>
              <ul className="divide-y divide-gray-100 border border-gray-200 rounded-lg">
                {reports.map((r) => <li key={r.id} className="px-3 py-2 text-sm flex flex-wrap items-center gap-2"><span className="font-medium">{r.title}</span>{r.decision && <Badge className="bg-indigo-50 text-indigo-700 ring-indigo-600/20">{{ scale: 'Mở rộng', extend: 'Gia hạn', stop: 'Dừng' }[r.decision]}</Badge>}<span className="text-xs text-gray-500">{new Date(r.created_at).toLocaleString('vi-VN')}{r.decision_note && ` · ${r.decision_note}`}</span><span className="ml-auto flex gap-2"><button className={btn.ghost} onClick={() => setPreview(r.markdown)}>Xem</button><button className={btn.ghost} onClick={() => download(r.markdown, `${r.title}.md`)}>Tải</button></span></li>)}
              </ul>
            </div>
          )}
        </div>
      </Card>
    </>
  );
}

function Row({ l, v }: { l: string; v: string }) {
  return <div className="flex justify-between gap-3"><dt className="text-gray-600">{l}</dt><dd className="font-semibold tabular-nums">{v}</dd></div>;
}
