'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { usd } from '@/lib/format';
import { Card, CardHeader, Badge, Spinner, btn } from '@/components/ui';

type Meas = {
  id: string; subject_type: 'action' | 'content_version'; subject_id: string; asin: string | null; change_at: string; window_days: number;
  baseline: { days: number; cp_per_day: number | null; cvr: number | null; sessions: number }; observed: { days: number; cp_per_day: number | null; cvr: number | null; sessions: number };
  control: { n: number; change_pct: number } | null; concurrent_changes: { type: string; msg: string }[];
  incremental_cp_per_day: number | null; incremental_cp_total: number | null; ci_low: number | null; ci_high: number | null; cvr_delta_pct: number | null;
  confidence: 'insufficient_data' | 'low' | 'confounded' | 'moderate' | 'high'; note: string | null; is_final: boolean; measured_at: string;
};
type Kpi = Record<string, number | null>;

const CONF: Record<Meas['confidence'], { label: string; cls: string }> = {
  high: { label: 'Cao', cls: 'bg-emerald-100 text-emerald-800' },
  moderate: { label: 'Vừa', cls: 'bg-sky-100 text-sky-800' },
  confounded: { label: 'Nhiễu (thay đổi đồng thời)', cls: 'bg-amber-100 text-amber-800' },
  low: { label: 'Thấp', cls: 'bg-gray-100 text-gray-700' },
  insufficient_data: { label: 'Thiếu dữ liệu', cls: 'bg-gray-100 text-gray-500' },
};
const pct = (x: number | null | undefined, s = '') => (x == null ? '—' : `${x}${s}%`);
const n = (x: number | null | undefined) => (x == null ? '—' : String(x));
const h = (x: number | null | undefined) => (x == null ? '—' : x < 48 ? `${x} giờ` : `${(x / 24).toFixed(1)} ngày`);

/** Sổ đo lường + KPI content/AI (P0‑6). Tự ẩn nếu chưa chạy 016. */
export default function MeasurementLedger({ tenantId, canWrite, days }: { tenantId: string | null | undefined; canWrite: boolean; days: number }) {
  const [rows, setRows] = React.useState<Meas[] | null>(null);
  const [ck, setCk] = React.useState<Kpi | null>(null);
  const [ak, setAk] = React.useState<Kpi | null>(null);
  const [missing, setMissing] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    if (!tenantId) return;
    const [m, c, a] = await Promise.all([
      supabase.from('measurements').select('*').eq('tenant_id', tenantId).order('change_at', { ascending: false }).limit(200),
      supabase.rpc('content_kpi', { t: tenantId, p_days: 30 }),
      supabase.rpc('ai_quality_kpi', { t: tenantId, p_days: 30 }),
    ]);
    if (m.error) { setMissing(true); return; }
    setRows((m.data ?? []) as Meas[]);
    setCk((c.data ?? null) as Kpi | null); setAk((a.data ?? null) as Kpi | null);
  }, [tenantId]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch
    void load();
  }, [load]);

  const run = async () => {
    if (!tenantId) return; setBusy(true); setMsg(null);
    const r1 = await supabase.rpc('measure_all', { t: tenantId, p_days: days });
    const r2 = await supabase.rpc('finalize_measurements', { t: tenantId });
    setBusy(false);
    setMsg(r1.error ? r1.error.message : `Đã đo ${r1.data} thay đổi · đóng băng ${r2.data ?? 0} bản ghi`);
    void load();
  };

  if (missing) return null;
  if (!rows) return <Spinner label="Đang tải sổ đo lường…" />;

  const confident = rows.filter((r) => ['moderate', 'high'].includes(r.confidence));
  const confounded = rows.filter((r) => r.confidence === 'confounded');
  const sumConf = confident.reduce((s, r) => s + (r.incremental_cp_total ?? 0), 0);

  return (
    <>
      {/* KPI content / AI */}
      <div className="grid gap-4 lg:grid-cols-2 mb-4">
        <Card>
          <CardHeader title="KPI Content (30 ngày)" subtitle="Từ content_versions / product_facts / sổ đo lường. Cycle time tính theo mốc qa_at, brand_at, published_at." />
          <dl className="px-5 py-3 grid grid-cols-2 gap-x-6 gap-y-1.5 text-sm">
            <Row l="Draft tạo / AI draft" v={`${n(ck?.drafts_created)} / ${n(ck?.ai_drafts)}`} />
            <Row l="Đã publish" v={n(ck?.published)} />
            <Row l="Đang chờ (QA/Brand)" v={`${n(ck?.in_flight)} · chờ brand ${n(ck?.awaiting_brand)}`} />
            <Row l="First‑pass QA" v={pct(ck?.first_pass_qa_pct)} />
            <Row l="Bị compliance chặn" v={`${pct(ck?.compliance_block_pct)} · override ${n(ck?.compliance_override_count)}`} />
            <Row l="Publish có evidence" v={pct(ck?.published_with_evidence_pct)} />
            <Row l="Publish có fact verified" v={pct(ck?.published_with_verified_facts_pct)} />
            <Row l="Draft → QA" v={h(ck?.hours_draft_to_qa)} />
            <Row l="QA → Brand duyệt" v={h(ck?.hours_qa_to_brand)} />
            <Row l="Draft → Publish" v={h(ck?.hours_draft_to_publish)} />
            <Row l="Rollback" v={`${n(ck?.rollbacks)} (${pct(ck?.rollback_rate_pct)})`} />
            <Row l="ΔCVR trung vị (đo tin cậy)" v={pct(ck?.median_cvr_delta_pct, '')} />
          </dl>
        </Card>
        <Card>
          <CardHeader title="KPI chất lượng AI / rule (30 ngày)" subtitle="Acceptance, override, precision, rollback. Gợi ý do người thực hiện không được tính là tự động hoá." />
          <dl className="px-5 py-3 grid grid-cols-2 gap-x-6 gap-y-1.5 text-sm">
            <Row l="Gợi ý: chấp nhận / từ chối" v={`${pct(ak?.rec_acceptance_pct)} / ${pct(ak?.rec_reject_pct)} (${n(ak?.rec_total)})`} />
            <Row l="Gợi ý có lý do" v={pct(ak?.rec_with_rationale_pct)} />
            <Row l="SoD override" v={n(ak?.rec_sod_overrides)} />
            <Row l="AI content: chấp nhận" v={`${pct(ak?.ai_content_accept_pct)} (${n(ak?.ai_content_drafts)} draft)`} />
            <Row l="AI content: rollback" v={pct(ak?.ai_content_rollback_pct)} />
            <Row l="Tin phản hồi: chấp nhận" v={`${pct(ak?.response_accept_pct)} · chặn policy ${n(ak?.policy_blocks_response)}`} />
            <Row l="Ngoại lệ precision" v={pct(ak?.exception_precision_pct)} />
            <Row l="Phân loại review precision" v={`${pct(ak?.classification_precision_pct)} (${n(ak?.classification_verified)} kiểm)`} />
            <Row l="Lệnh thật / rollback" v={`${n(ak?.actions_real)} / ${n(ak?.actions_rolled_back)}`} />
            <Row l="Lệnh đã đo (post‑measurement)" v={pct(ak?.actions_measured_pct)} />
            <Row l="Đo tin cậy / nhiễu" v={`${n(ak?.actions_confident)} / ${n(ak?.actions_confounded)}`} />
            <Row l="Incremental CP dương" v={pct(ak?.incremental_cp_positive_pct)} />
          </dl>
        </Card>
      </div>

      {/* Sổ đo lường */}
      <Card className="mb-4">
        <CardHeader title="Sổ đo lường (baseline đóng băng · đối chứng · thay đổi đồng thời)"
          subtitle={`Chỉ ${confident.length} bản đo tin cậy được cộng vào North Star: ${usd(sumConf, 0)}. ${confounded.length} bản nhiễu hiển thị riêng — KHÔNG chia attribution. Đóng băng sau cửa sổ + 28 ngày.`}
          action={canWrite ? <button className={btn.secondary} disabled={busy} onClick={run}>{busy ? '…' : `Đo lại (±${days} ngày)`}</button> : undefined} />
        {msg && <p className="px-5 pt-2 text-xs text-gray-600">{msg}</p>}
        <div className="overflow-x-auto px-5 py-3">
          {rows.length === 0 ? <p className="text-sm text-gray-500 py-4">Chưa có bản đo nào. Bấm “Đo lại” sau khi có lệnh thật hoặc content publish ≥ 3 ngày.</p> : (
            <table className="w-full text-sm">
              <thead className="text-left text-xs uppercase text-gray-500 border-b">
                <tr><th className="py-2 pr-3">Thay đổi</th><th className="pr-3">ASIN</th><th className="pr-3">Ngày</th><th className="pr-3 text-right">CP/ngày trước → sau</th><th className="pr-3 text-right">Đối chứng</th><th className="pr-3 text-right">Incremental CP</th><th className="pr-3 text-right">CI 95%</th><th className="pr-3 text-right">ΔCVR</th><th className="pr-3">Tin cậy</th><th>Thay đổi đồng thời / ghi chú</th></tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className={`border-b last:border-0 align-top ${r.confidence === 'confounded' ? 'bg-amber-50/40' : ''}`}>
                    <td className="py-2 pr-3">{r.subject_type === 'action' ? 'Lệnh' : 'Content'}{r.is_final && <span className="ml-1 text-[10px] text-gray-400">🔒 final</span>}<div className="text-[10px] text-gray-400">±{r.window_days}d</div></td>
                    <td className="pr-3 font-mono text-xs">{r.asin ?? '—'}</td>
                    <td className="pr-3 text-gray-600">{new Date(r.change_at).toLocaleDateString('vi-VN')}</td>
                    <td className="pr-3 text-right tabular-nums">{usd(r.baseline.cp_per_day)} → {usd(r.observed.cp_per_day)}</td>
                    <td className="pr-3 text-right tabular-nums text-gray-500">{r.control ? `${r.control.n} ASIN · ${r.control.change_pct}%` : '—'}</td>
                    <td className={`pr-3 text-right tabular-nums font-semibold ${r.incremental_cp_total == null ? 'text-gray-400' : r.incremental_cp_total >= 0 ? 'text-emerald-700' : 'text-red-600'}`}>{usd(r.incremental_cp_total, 0)}</td>
                    <td className="pr-3 text-right tabular-nums text-xs">{r.ci_low != null ? `${usd(r.ci_low, 0)} … ${usd(r.ci_high, 0)}` : '—'}</td>
                    <td className="pr-3 text-right tabular-nums">{r.cvr_delta_pct != null ? `${r.cvr_delta_pct > 0 ? '+' : ''}${r.cvr_delta_pct}%` : '—'}</td>
                    <td className="pr-3"><Badge className={CONF[r.confidence].cls}>{CONF[r.confidence].label}</Badge></td>
                    <td className="text-xs text-gray-600 max-w-[280px]">
                      {r.concurrent_changes.length > 0 && <ul className="list-disc pl-4">{r.concurrent_changes.map((c, i) => <li key={i}>{c.msg}</li>)}</ul>}
                      {r.note && <p className="text-gray-500">{r.note}</p>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </Card>
    </>
  );
}

function Row({ l, v }: { l: string; v: string }) {
  return <div className="flex justify-between gap-3 border-b border-gray-50 py-0.5"><dt className="text-gray-600">{l}</dt><dd className="font-semibold tabular-nums text-right">{v}</dd></div>;
}
