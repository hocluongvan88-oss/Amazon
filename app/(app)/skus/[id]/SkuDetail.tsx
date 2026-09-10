'use client';

import React from 'react';
import ControlRoom from '@/components/ControlRoom';
import { LIMITS } from '@/lib/limits';
import RiskBreakdown, { type RiskComponents } from '@/components/RiskBreakdown';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { usd, num, pct, riskLevel, RISK_META, REC_TYPE_LABEL, REC_STATUS } from '@/lib/format';
import { Card, CardHeader, Badge, Spinner, ErrorBox, EmptyState, btn, input } from '@/components/ui';
import { RiskHistoryChart, UnitsChart, PriceProfitChart, InventoryChart, AdsChart, enrich, fillDays, type DailyPoint } from '@/components/charts';

type Sku = {
  id: string; asin: string; sku: string | null; title: string; status: string; marketplace: string; supplier: string | null; lead_time_days: number | null; inventory_inbound: number | null;
  current_price: number; list_price: number | null; cogs: number; fee_per_unit: number; referral_fee_pct: number; contribution_profit: number;
  sales_last_30d: number; revenue_last_30d: number | null; sessions_last_30d: number | null; inventory_qty: number; reorder_point: number;
  stockout_risk_score: number; risk_score: number | null; risk_components: RiskComponents; risk_computed_at: string | null; cogs_source: string | null; fee_source: string | null; cogs_updated_at: string | null; fee_updated_at: string | null; last_ingested_at: string | null;
};
type Metrics = {
  velocity_7d: number | null; velocity_30d: number | null; velocity_change_pct: number | null; coverage_days_30: number;
  units_30d: number | null; revenue_30d: number | null; cp_30d: number | null; price_avg_30: number | null; price_volatility_pct: number | null;
  cp_unit_now: number; cp_margin_now_pct: number | null; cp_margin_baseline_pct: number | null; margin_delta_pts: number | null;
  days_of_cover: number | null; stockout_eta: string | null; inventory_health: string;
  tacos_30: number | null; acos_30: number | null; cvr_30: number | null; ad_spend_30: number | null;
  last_sale_date: string | null; days_since_last_sale: number | null; snapshots_total: number; first_snapshot: string | null; last_snapshot: string | null;
};
type Rec = { id: string; type: string; title: string | null; status: string; risk_score: number; expected_impact: number | null; approval_tier: string; created_at: string };
type Exc = { id: string; code: string; message: string; resolved: boolean; created_at: string };
type Review = { id: string; rating: number; title: string | null; body: string; verified_purchase: boolean; reviewed_at: string | null; created_at: string };
type Cogs = { id: string; effective_from: string; cogs: number; landed_cost: number | null; source: string; note: string | null };

const HEALTH: Record<string, { label: string; cls: string }> = {
  critical: { label: 'Nguy cấp', cls: 'bg-red-50 text-red-700 ring-red-600/20' },
  warning: { label: 'Cảnh báo', cls: 'bg-orange-50 text-orange-700 ring-orange-600/20' },
  healthy: { label: 'Ổn', cls: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' },
  overstock: { label: 'Tồn dư', cls: 'bg-blue-50 text-blue-700 ring-blue-600/20' },
  unknown: { label: 'Chưa rõ', cls: 'bg-gray-50 text-gray-600 ring-gray-500/20' },
};

export default function SkuDetail({ id }: { id: string }) {
  const { tenant, can } = useTenant();
  const canWrite = can('sku.write');
  const [sku, setSku] = React.useState<Sku | null>(null);
  const [m, setM] = React.useState<Metrics | null>(null);
  const [daily, setDaily] = React.useState<DailyPoint[]>([]);
  const [recs, setRecs] = React.useState<Rec[]>([]);
  const [excs, setExcs] = React.useState<Exc[]>([]);
  const [reviews, setReviews] = React.useState<Review[]>([]);
  const [cogs, setCogs] = React.useState<Cogs[]>([]);
  const [riskHist, setRiskHist] = React.useState<{ date: string; risk_score: number }[]>([]);
  const [range, setRange] = React.useState<30 | 90>(30);
  const [tab, setTab] = React.useState<'recs' | 'excs' | 'reviews' | 'cogs' | 'snaps'>('recs');
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [editing, setEditing] = React.useState(false);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const since = new Date(Date.now() - 89 * 86400000).toISOString().slice(0, 10);
    const { data: head } = await supabase.from('amazon_skus').select('asin').eq('id', id).eq('tenant_id', tenant.id).maybeSingle();
    const asin = head?.asin ?? '';
    const [s, mt, d, r, e, rv, ch, rh] = await Promise.all([
      supabase.from('amazon_skus').select('*').eq('id', id).eq('tenant_id', tenant.id).maybeSingle(),
      supabase.rpc('sku_metrics', { t: tenant.id, asof: new Date().toISOString().slice(0, 10), only_sku: id }),
      supabase.from('sku_daily_snapshots').select('date,units,revenue,price,contribution_profit,inventory_qty,reorder_point,ad_spend,ad_sales').eq('sku_id', id).gte('date', since).order('date').limit(LIMITS.chartDays),
      supabase.from('recommendations').select('id,type,title,status,risk_score,expected_impact,approval_tier,created_at').eq('sku_id', id).order('created_at', { ascending: false }).limit(LIMITS.detailItems),
      supabase.from('exceptions').select('id,code,message,resolved,created_at').eq('tenant_id', tenant.id).eq('asin', asin).order('created_at', { ascending: false }).limit(LIMITS.detailItems),
      supabase.from('raw_reviews').select('id,rating,title,body,verified_purchase,reviewed_at,created_at').eq('tenant_id', tenant.id).eq('asin', asin).order('created_at', { ascending: false }).limit(LIMITS.detailItems),
      supabase.from('cogs_history').select('id,effective_from,cogs,landed_cost,source,note').eq('sku_id', id).order('effective_from', { ascending: false }).limit(LIMITS.detailItems),
      supabase.from('risk_history').select('date,risk_score').eq('sku_id', id).gte('date', since).order('date').limit(LIMITS.chartDays),
    ]);
    if (s.error) { setError(s.error.message); setLoading(false); return; }
    if (!s.data) { setError('Không tìm thấy ASIN trong brand hiện tại.'); setLoading(false); return; }
    const k = s.data as Sku;
    setSku(k);
    setM(((mt.data as Metrics[] | null) ?? [])[0] ?? null);
    setDaily(((d.data ?? []) as DailyPoint[]).map((x) => ({ ...x, cp: x.units != null && x.contribution_profit != null ? x.units * x.contribution_profit : null })));
    setRecs((r.data ?? []) as Rec[]);
    setExcs(((e.data ?? []) as (Exc & { asin?: string })[]).filter((x) => !('asin' in x) || x.asin === k.asin));
    setReviews(((rv.data ?? []) as (Review & { asin?: string })[]).filter((x) => !('asin' in x) || x.asin === k.asin));
    setCogs((ch.data ?? []) as Cogs[]);
    setRiskHist(((rh.data ?? []) as { date: string; risk_score: number }[]).map((x) => ({ ...x, risk_score: Number(x.risk_score) })));
    setLoading(false);
  }, [tenant, id]);

  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch
    void load();
  }, [load]);

  if (loading) return <Spinner />;
  if (error || !sku) return <ErrorBox message={error ?? 'Lỗi'} />;

  const series = enrich(fillDays(daily, range));
  const hasSales = daily.some((d) => d.units != null);
  const hasAds = daily.some((d) => d.ad_spend != null);
  const hasState = daily.some((d) => d.price != null);
  const margin = sku.current_price ? (Number(sku.contribution_profit) / Number(sku.current_price)) * 100 : 0;
  const risk = Number(sku.risk_score ?? sku.stockout_risk_score);
  const lvl = riskLevel(risk);
  const health = HEALTH[m?.inventory_health ?? 'unknown'];
  const thin = (m?.coverage_days_30 ?? 0) < 20;

  return (
    <>
      {/* Header */}
      <div className="mb-5">
        <Link href="/" className="text-sm text-indigo-600 hover:underline">← Tổng quan</Link>
        <div className="mt-1 flex flex-col lg:flex-row lg:items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-gray-900">{sku.title}</h1>
            <p className="mt-1 text-sm text-gray-500 flex flex-wrap items-center gap-2">
              <span className="font-mono">{sku.asin}</span>{sku.sku && <span className="font-mono">· {sku.sku}</span>}
              <span>· {sku.marketplace}</span>
              <Badge className={sku.status === 'active' ? 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' : 'bg-gray-100 text-gray-600 ring-gray-500/20'}>{sku.status === 'active' ? 'Đang bán' : sku.status === 'paused' ? 'Tạm dừng' : 'Lưu trữ'}</Badge>
              {sku.supplier && <span>· NCC {sku.supplier}</span>}
              {sku.lead_time_days != null && <span>· lead time {sku.lead_time_days} ngày</span>}
            </p>
          </div>
          <div className="flex gap-2 shrink-0">
            <Link href={`/recommendations?asin=${sku.asin}`} className={btn.secondary}>Gợi ý của ASIN</Link>
            {canWrite && <button className={btn.primary} onClick={() => setEditing(true)}>Sửa thông tin</button>}
          </div>
        </div>
      </div>

      {/* Tiles */}
      <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3 mb-5">
        <Tile label="Giá bán" value={usd(sku.current_price)} hint={sku.list_price ? `Niêm yết ${usd(sku.list_price)}` : m?.price_volatility_pct != null ? `Biến động 30d ${m.price_volatility_pct}%` : undefined} />
        <Tile label="LN góp phần / đv" value={usd(sku.contribution_profit)} tone={Number(sku.contribution_profit) < 0 ? 'red' : 'green'}
          hint={`Biên ${margin.toFixed(1)}%${m?.margin_delta_pts != null ? ` · Δ ${m.margin_delta_pts > 0 ? '+' : ''}${m.margin_delta_pts} pts vs baseline` : ''}`} />
        <Tile label="Bán / ngày (7d · 30d)" value={m?.velocity_7d != null ? `${m.velocity_7d} · ${m.velocity_30d ?? '—'}` : num(sku.sales_last_30d / 30, 1)}
          hint={m?.velocity_change_pct != null ? `${m.velocity_change_pct > 0 ? '▲' : '▼'} ${Math.abs(m.velocity_change_pct)}% so với 30d` : `${num(sku.sales_last_30d)} đv/30 ngày (báo cáo)`}
          tone={m?.velocity_change_pct != null ? (m.velocity_change_pct < -20 ? 'red' : m.velocity_change_pct > 20 ? 'green' : 'default') : 'default'} />
        <Tile label="Doanh thu 30 ngày" value={usd(m?.revenue_30d ?? sku.revenue_last_30d ?? sku.current_price * sku.sales_last_30d, 0)}
          hint={m?.cp_30d != null ? `LN góp phần ${usd(m.cp_30d, 0)}` : `LN góp phần ≈ ${usd(Number(sku.contribution_profit) * sku.sales_last_30d, 0)}`} />
        <Tile label="Tồn kho" value={num(sku.inventory_qty)} tone={sku.inventory_qty < sku.reorder_point ? 'red' : 'default'}
          hint={m?.days_of_cover != null ? `${m.days_of_cover} ngày hàng${m.stockout_eta ? ` · hết ~${new Date(m.stockout_eta).toLocaleDateString('vi-VN')}` : ''}` : `ROP ${num(sku.reorder_point)}`}
          badge={<Badge className={health.cls}>{health.label}</Badge>} />
        <Tile label="TACoS · CVR (30d)" value={m?.tacos_30 != null || m?.cvr_30 != null ? `${m?.tacos_30 != null ? pct(m.tacos_30) : '—'} · ${m?.cvr_30 != null ? pct(m.cvr_30) : '—'}` : '—'}
          hint={m?.ad_spend_30 != null ? `QC ${usd(m.ad_spend_30, 0)} · ACoS ${m.acos_30 != null ? pct(m.acos_30) : '—'}` : 'Chưa có dữ liệu quảng cáo / sessions'} />
      </div>

      {/* Risk breakdown */}
      <Card className="mb-5">
        <CardHeader title="Vì sao rủi ro" subtitle={`Điểm tổng hợp ${risk.toFixed(0)}/100 · ${RISK_META[lvl].label}${sku.risk_computed_at ? ` · tính lúc ${new Date(sku.risk_computed_at).toLocaleString('vi-VN')}` : ''}`}
          action={<Badge className={RISK_META[lvl].cls}>{risk.toFixed(0)}</Badge>} />
        <div className="p-5 grid lg:grid-cols-2 gap-6">
          <RiskBreakdown c={sku.risk_components} total={risk} />
          <div>
            <p className="text-xs font-medium text-gray-700 mb-1">Diễn biến 90 ngày</p>
            {riskHist.length < 2 ? <p className="text-xs text-gray-500">Chưa đủ lịch sử (ghi mỗi lần chạy rule, 1 điểm/ngày).</p> : <RiskHistoryChart data={riskHist} />}
          </div>
        </div>
      </Card>

      {thin && (
        <div className="mb-5 rounded-lg bg-yellow-50 border border-yellow-200 p-3 text-sm text-yellow-900">
          Dữ liệu bán theo ngày còn mỏng ({m?.coverage_days_30 ?? 0}/30 ngày). Velocity và ETA hết hàng có thể chưa chính xác –
          {canWrite ? <> nhập <Link href="/import" className="underline">đơn hàng theo ngày</Link> để cải thiện.</> : ' cần nhập thêm đơn hàng theo ngày.'}
        </div>
      )}

      {/* Charts */}
      <div className="flex items-center justify-between mb-2">
        <h2 className="text-base font-semibold text-gray-900">Xu hướng</h2>
        <div className="flex gap-1">
          {[30, 90].map((r) => <button key={r} onClick={() => setRange(r as 30 | 90)} className={`px-2.5 py-1 text-xs rounded-md ${range === r ? 'bg-slate-900 text-white' : 'bg-white border border-gray-200 text-gray-700'}`}>{r} ngày</button>)}
        </div>
      </div>
      <div className="grid lg:grid-cols-2 gap-4 mb-6">
        <ChartCard title="Đơn vị bán / ngày" empty={!hasSales} emptyHint="Nhập file All Orders để có dữ liệu theo ngày."><UnitsChart data={series} /></ChartCard>
        <ChartCard title="Giá & lợi nhuận góp phần / đơn vị" empty={!hasState} emptyHint="Snapshot hằng ngày sẽ tích luỹ từ hôm nay."><PriceProfitChart data={series} /></ChartCard>
        <ChartCard title="Tồn kho" empty={!hasState} emptyHint="Snapshot hằng ngày sẽ tích luỹ từ hôm nay."><InventoryChart data={series} reorderPoint={sku.reorder_point} eta={m?.stockout_eta ?? null} /></ChartCard>
        <ChartCard title="Quảng cáo & TACoS" empty={!hasAds} emptyHint="Nhập báo cáo Sponsored Products theo ngày (tuỳ chọn)."><AdsChart data={series} /></ChartCard>
      </div>

      {/* ASIN Control Room (P0‑4) */}
      <ControlRoom skuId={sku.id} asin={sku.asin} canWrite={can('voc.triage') || can('content.draft') || can('exception.resolve')} />

      {/* Tabs */}
      <Card>
        <div className="px-5 pt-3 flex flex-wrap gap-1 border-b border-gray-100">
          {([['recs', `Gợi ý (${recs.length})`], ['excs', `Ngoại lệ (${excs.filter((x) => !x.resolved).length})`], ['reviews', `Review (${reviews.length})`], ['cogs', `Lịch sử COGS (${cogs.length})`], ['snaps', 'Snapshot 30 ngày']] as const).map(([k, l]) => (
            <button key={k} onClick={() => setTab(k)} className={`px-3 py-2 text-sm font-medium border-b-2 -mb-px ${tab === k ? 'border-indigo-600 text-indigo-700' : 'border-transparent text-gray-500 hover:text-gray-800'}`}>{l}</button>
          ))}
        </div>
        {tab === 'recs' && (recs.length === 0 ? <EmptyState title="Chưa có gợi ý cho ASIN này" /> : (
          <ul className="divide-y divide-gray-100">
            {recs.map((r) => (
              <li key={r.id} className="px-5 py-3 flex flex-wrap items-center gap-3 text-sm">
                <Badge className="bg-indigo-50 text-indigo-700 ring-indigo-600/20">{REC_TYPE_LABEL[r.type] ?? r.type}</Badge>
                <span className={`text-xs px-2 py-0.5 rounded-md ${REC_STATUS[r.status]?.cls ?? ''}`}>{REC_STATUS[r.status]?.label ?? r.status}</span>
                <span className="flex-1 text-gray-900 truncate">{r.title}</span>
                <span className="text-xs text-gray-500">{r.approval_tier} · rủi ro {Number(r.risk_score).toFixed(0)}</span>
                {r.expected_impact != null && <span className="text-emerald-700 font-medium">+{usd(r.expected_impact, 0)}/th</span>}
                <Link href={`/recommendations?asin=${sku.asin}`} className={btn.ghost}>Mở →</Link>
              </li>
            ))}
          </ul>
        ))}
        {tab === 'excs' && (excs.length === 0 ? <EmptyState title="Không có ngoại lệ" /> : (
          <ul className="divide-y divide-gray-100">
            {excs.map((e) => (
              <li key={e.id} className={`px-5 py-3 flex items-center gap-3 text-sm ${e.resolved ? 'opacity-60' : ''}`}>
                <Badge className={e.code <= 'P1' ? 'bg-red-50 text-red-700 ring-red-600/20' : 'bg-yellow-50 text-yellow-800 ring-yellow-600/20'}>{e.code}</Badge>
                <span className="flex-1 text-gray-900">{e.message}</span>
                <span className="text-xs text-gray-500">{new Date(e.created_at).toLocaleDateString('vi-VN')}{e.resolved && ' · đã xử lý'}</span>
              </li>
            ))}
          </ul>
        ))}
        {tab === 'reviews' && (reviews.length === 0 ? <EmptyState title="Chưa có review" description="Module Review/VOC sẽ bổ sung ở tuần 9–10 (chỉ listening/triage)." /> : (
          <ul className="divide-y divide-gray-100">
            {reviews.map((r) => (
              <li key={r.id} className="px-5 py-3 text-sm">
                <div className="flex items-center gap-2">
                  <span className={`font-semibold ${r.rating <= 2 ? 'text-red-600' : r.rating === 3 ? 'text-yellow-700' : 'text-emerald-700'}`}>{'★'.repeat(r.rating)}{'☆'.repeat(5 - r.rating)}</span>
                  <span className="font-medium text-gray-900">{r.title}</span>
                  {r.verified_purchase && <Badge className="bg-gray-50 text-gray-600 ring-gray-500/20">Verified</Badge>}
                  <span className="ml-auto text-xs text-gray-400">{new Date(r.reviewed_at ?? r.created_at).toLocaleDateString('vi-VN')}</span>
                </div>
                <p className="mt-1 text-gray-700">{r.body}</p>
              </li>
            ))}
          </ul>
        ))}
        {tab === 'cogs' && (cogs.length === 0 ? <EmptyState title="Chưa có lịch sử COGS" /> : (
          <table className="w-full text-sm">
            <thead className="bg-gray-50 text-xs uppercase text-gray-500"><tr><th className="px-5 py-2 text-left">Hiệu lực từ</th><th className="px-4 py-2 text-right">COGS</th><th className="px-4 py-2 text-right">Landed</th><th className="px-4 py-2 text-left">Nguồn</th><th className="px-4 py-2 text-left">Ghi chú</th></tr></thead>
            <tbody className="divide-y divide-gray-100">
              {cogs.map((c) => <tr key={c.id}><td className="px-5 py-2">{new Date(c.effective_from).toLocaleDateString('vi-VN')}</td><td className="px-4 py-2 text-right tabular-nums">{usd(c.cogs)}</td><td className="px-4 py-2 text-right tabular-nums">{c.landed_cost != null ? usd(c.landed_cost) : '—'}</td><td className="px-4 py-2">{c.source}</td><td className="px-4 py-2 text-gray-600">{c.note}</td></tr>)}
            </tbody>
          </table>
        ))}
        {tab === 'snaps' && (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead className="bg-gray-50 uppercase text-gray-500"><tr>{['Ngày', 'Đơn vị', 'Doanh thu', 'Giá', 'CP/đv', 'Tồn', 'QC', 'DT QC'].map((h) => <th key={h} className="px-3 py-2 text-right first:text-left">{h}</th>)}</tr></thead>
              <tbody className="divide-y divide-gray-100">
                {[...daily].reverse().slice(0, 30).map((d) => (
                  <tr key={d.date}>
                    <td className="px-3 py-1.5">{new Date(d.date).toLocaleDateString('vi-VN')}</td>
                    <Td v={d.units} /><Td v={d.revenue} usd /><Td v={d.price} usd /><Td v={d.contribution_profit} usd /><Td v={d.inventory_qty} /><Td v={d.ad_spend} usd /><Td v={(d as { ad_sales?: number | null }).ad_sales} usd />
                  </tr>
                ))}
                {daily.length === 0 && <tr><td colSpan={8}><EmptyState title="Chưa có snapshot" /></td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <p className="mt-4 text-xs text-gray-500">
        COGS: {sku.cogs_source ?? '—'}{sku.cogs_updated_at && ` (${new Date(sku.cogs_updated_at).toLocaleDateString('vi-VN')})`} · Phí: {sku.fee_source ?? '—'}{sku.fee_updated_at && ` (${new Date(sku.fee_updated_at).toLocaleDateString('vi-VN')})`} · Nhập gần nhất: {sku.last_ingested_at ? new Date(sku.last_ingested_at).toLocaleString('vi-VN') : '—'} · Rủi ro hết hàng: <Badge className={RISK_META[lvl].cls}>{risk.toFixed(0)}</Badge>
      </p>

      {editing && <EditModal sku={sku} onClose={() => setEditing(false)} onSaved={() => { setEditing(false); load(); }} />}
    </>
  );
}

function Tile({ label, value, hint, tone = 'default', badge }: { label: string; value: React.ReactNode; hint?: string; tone?: 'default' | 'green' | 'red'; badge?: React.ReactNode }) {
  const c = { default: 'text-gray-900', green: 'text-emerald-700', red: 'text-red-600' }[tone];
  return (
    <Card className="p-4">
      <div className="flex items-center justify-between gap-2"><p className="text-xs font-medium text-gray-500">{label}</p>{badge}</div>
      <p className={`mt-1 text-xl font-bold tabular-nums ${c}`}>{value}</p>
      {hint && <p className="mt-0.5 text-xs text-gray-500">{hint}</p>}
    </Card>
  );
}
function ChartCard({ title, empty, emptyHint, children }: { title: string; empty: boolean; emptyHint: string; children: React.ReactNode }) {
  return (
    <Card>
      <CardHeader title={title} />
      <div className="p-3">{empty ? <EmptyState title="Chưa có dữ liệu" description={emptyHint} /> : children}</div>
    </Card>
  );
}
function Td({ v, usd: isUsd }: { v: number | null | undefined; usd?: boolean }) {
  return <td className="px-3 py-1.5 text-right tabular-nums">{v == null ? <span className="text-gray-300">—</span> : isUsd ? usd(v) : num(v)}</td>;
}

/* ---------- Edit modal ---------- */
function EditModal({ sku, onClose, onSaved }: { sku: Sku; onClose: () => void; onSaved: () => void }) {
  const router = useRouter();
  const { tenant } = useTenant();
  const [f, setF] = React.useState({
    title: sku.title, sku: sku.sku ?? '', current_price: String(sku.current_price), list_price: sku.list_price != null ? String(sku.list_price) : '',
    fee_per_unit: String(sku.fee_per_unit), referral_fee_pct: String(sku.referral_fee_pct), inventory_qty: String(sku.inventory_qty), inventory_inbound: String(sku.inventory_inbound ?? 0), reorder_point: String(sku.reorder_point),
    lead_time_days: sku.lead_time_days != null ? String(sku.lead_time_days) : '', supplier: sku.supplier ?? '', status: sku.status,
    new_cogs: '', cogs_note: '',
  });
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const n = (v: string) => (v === '' ? null : Number(v));

  async function save() {
    if (!tenant) return;
    setBusy(true); setErr(null);
    const patch: Record<string, unknown> = {
      title: f.title.trim(), sku: f.sku.trim() || null, current_price: n(f.current_price), list_price: n(f.list_price),
      fee_per_unit: n(f.fee_per_unit) ?? 0, referral_fee_pct: n(f.referral_fee_pct) ?? 15, inventory_qty: n(f.inventory_qty) ?? 0, reorder_point: n(f.reorder_point) ?? 0,
      lead_time_days: n(f.lead_time_days), inventory_inbound: n(f.inventory_inbound) ?? 0, supplier: f.supplier.trim() || null, status: f.status,
    };
    const newCogs = f.new_cogs !== '' && Number(f.new_cogs) !== Number(sku.cogs) ? Number(f.new_cogs) : null;
    const { error } = await supabase.rpc('sku_save', { p_tenant: tenant.id, p_sku: sku.id, p_patch: patch, p_new_cogs: newCogs, p_cogs_note: newCogs != null ? (f.cogs_note || null) : null });
    if (error) { setErr(error.message); setBusy(false); return; }
    setBusy(false); onSaved(); router.refresh();
  }

  async function remove() {
    if (!confirm('Lưu trữ ASIN này? Nó sẽ ẩn khỏi Tổng quan nhưng dữ liệu lịch sử được giữ.')) return;
    if (!tenant) return;
    const { error } = await supabase.rpc('sku_save', { p_tenant: tenant.id, p_sku: sku.id, p_patch: { status: 'archived' } });
    if (error) { setErr(error.message); return; }
    onSaved();
  }

  const fp = { f, set };

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4" onClick={onClose}>
      <div className="bg-white rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-auto" onClick={(e) => e.stopPropagation()}>
        <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between"><h3 className="font-semibold text-gray-900">Sửa {sku.asin}</h3><button onClick={onClose} className="text-gray-400 hover:text-gray-700">✕</button></div>
        <div className="p-5 grid sm:grid-cols-2 gap-4">
          <div className="sm:col-span-2"><Fld {...fp} label="Tên sản phẩm" k="title" /></div>
          <Fld {...fp} label="SKU nội bộ" k="sku" />
          <div><label className="block text-xs font-medium text-gray-700 mb-1">Trạng thái</label>
            <select value={f.status} onChange={set('status')} className={input}><option value="active">Đang bán</option><option value="paused">Tạm dừng</option><option value="archived">Lưu trữ</option></select></div>
          <Fld {...fp} label="Giá bán (USD)" k="current_price" type="number" step="0.01" />
          <Fld {...fp} label="Giá niêm yết" k="list_price" type="number" step="0.01" />
          <Fld {...fp} label="Phí FBA / đv" k="fee_per_unit" type="number" step="0.01" />
          <Fld {...fp} label="Referral %" k="referral_fee_pct" type="number" step="0.01" />
          <Fld {...fp} label="Tồn kho" k="inventory_qty" type="number" step="1" />
          <Fld {...fp} label="Đang về (inbound)" k="inventory_inbound" type="number" step="1" />
          <Fld {...fp} label="Điểm đặt hàng lại" k="reorder_point" type="number" step="1" />
          <Fld {...fp} label="Lead time (ngày)" k="lead_time_days" type="number" step="1" />
          <Fld {...fp} label="Nhà cung cấp" k="supplier" />
          <div className="sm:col-span-2 rounded-lg bg-gray-50 border border-gray-200 p-3">
            <p className="text-xs font-medium text-gray-700 mb-2">COGS hiện tại: <b>{usd(sku.cogs)}</b>. Nhập giá vốn mới sẽ thêm một dòng lịch sử (hiệu lực hôm nay), không sửa đè.</p>
            <div className="grid sm:grid-cols-2 gap-3"><Fld {...fp} label="COGS mới (USD)" k="new_cogs" type="number" step="0.01" /><Fld {...fp} label="Ghi chú" k="cogs_note" /></div>
          </div>
        </div>
        {err && <div className="px-5"><ErrorBox message={err} /></div>}
        <div className="px-5 py-4 border-t border-gray-100 flex items-center justify-between">
          <button className="text-sm text-red-600 hover:underline" onClick={remove}>Lưu trữ ASIN</button>
          <div className="flex gap-2"><button className={btn.secondary} onClick={onClose}>Huỷ</button><button className={btn.primary} disabled={busy} onClick={save}>{busy ? 'Đang lưu…' : 'Lưu'}</button></div>
        </div>
      </div>
    </div>
  );
}

type FormShape = Record<string, string>;
function Fld({ f, set, label, k, type = 'text', step }: { f: FormShape; set: (k: never) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => void; label: string; k: string; type?: string; step?: string }) {
  return (
    <div>
      <label className="block text-xs font-medium text-gray-700 mb-1">{label}</label>
      <input type={type} step={step} value={f[k]} onChange={set(k as never)} className={input} />
    </div>
  );
}
