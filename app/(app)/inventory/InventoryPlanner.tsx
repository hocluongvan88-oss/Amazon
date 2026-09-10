'use client';

import React from 'react';
import { LIMITS } from '@/lib/limits';
import { Paged } from '@/components/ShowMore';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, EmptyState, Spinner, ErrorBox, btn } from '@/components/ui';
import { usd, num } from '@/lib/format';
import { ForecastChart, type ForecastPoint } from '@/components/charts';

type Plan = {
  sku_id: string; asin: string; title: string; on_hand: number; inbound: number; lead_time: number; safety_days: number; model: string | null; made_on: string | null; mape: number | null;
  v_fc: number; demand_lead: number; days_of_cover: number | null; stockout_date: string | null; order_by_date: string | null;
  target_cover_days: number; suggested_qty: number; status: string; stock_value: number; overstock_days: number | null;
};
type Acc = { model: string; skus: number; chosen_skus: number; avg_mape: number | null; avg_bias_pct: number | null };
type Policy = { default_lead_time_days: number; safety_stock_days: number };

const STATUS: Record<string, { label: string; cls: string; order: number }> = {
  stockout:   { label: 'Hết hàng',       cls: 'bg-red-600 text-white ring-red-700', order: 0 },
  order_now:  { label: 'Đặt ngay',       cls: 'bg-red-50 text-red-700 ring-red-600/20', order: 1 },
  order_soon: { label: 'Đặt sớm',        cls: 'bg-amber-50 text-amber-800 ring-amber-600/20', order: 2 },
  overstock:  { label: 'Tồn dư',         cls: 'bg-indigo-50 text-indigo-700 ring-indigo-600/20', order: 3 },
  no_demand:  { label: 'Không có cầu',   cls: 'bg-gray-100 text-gray-600 ring-gray-500/20', order: 4 },
  ok:         { label: 'Ổn',             cls: 'bg-emerald-50 text-emerald-700 ring-emerald-600/20', order: 5 },
};
const MODEL_LABEL: Record<string, string> = { naive7: 'TB 7 ngày (naive)', ma28: 'TB 28 ngày', ses_dow: 'Làm mượt mũ + thứ trong tuần', catalog_30d: 'Số 30 ngày danh mục' };

export default function InventoryPlanner() {
  const { tenant, canWrite } = useTenant();
  const [pol, setPol] = React.useState<Policy | null>(null);
  const [base, setBase] = React.useState<Plan[]>([]);
  const [scen, setScen] = React.useState<Plan[] | null>(null);   // null = dùng base
  const [acc, setAcc] = React.useState<Acc[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [scenLoading, setScenLoading] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [running, setRunning] = React.useState(false);
  const [creating, setCreating] = React.useState<string | null>(null);
  const [sel, setSel] = React.useState<string | null>(null);
  // scenario
  const [lt, setLt] = React.useState<number | null>(null);      // null = theo SKU/chính sách
  const [sd, setSd] = React.useState<number | null>(null);
  const [p90, setP90] = React.useState(false);
  const [inbound, setInbound] = React.useState(true);
  const [filter, setFilter] = React.useState('all');

  const loadBase = React.useCallback(async () => {
    if (!tenant) return;
    const [p, a, po] = await Promise.all([
      supabase.rpc('inventory_plan', { t: tenant.id }),
      supabase.from('v_forecast_accuracy').select('*').eq('tenant_id', tenant.id),
      supabase.from('policy_register').select('default_lead_time_days,safety_stock_days').eq('tenant_id', tenant.id).single(),
    ]);
    if (p.error) setError(p.error.message);
    else setBase(((p.data ?? []) as Plan[]).map(numify));
    setAcc((a.data ?? []) as Acc[]);
    setPol((po.data as Policy) ?? null);
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch on tenant change
    void loadBase();
  }, [loadBase]);

  const isScenario = lt != null || sd != null || p90 || !inbound;
  React.useEffect(() => {
    if (!tenant || !isScenario) return;
    const h = setTimeout(async () => {
      setScenLoading(true);
      const { data, error: e } = await supabase.rpc('inventory_plan', { t: tenant.id, p_lead_time: lt, p_safety_days: sd, p_use_p90: p90, p_count_inbound: inbound });
      if (!e) setScen(((data ?? []) as Plan[]).map(numify));
      setScenLoading(false);
    }, 300);
    return () => clearTimeout(h);
  }, [tenant, lt, sd, p90, inbound, isScenario]);
  const plans = isScenario && scen ? scen : base;

  async function runForecast() {
    if (!tenant) return;
    setRunning(true);
    const { error: e } = await supabase.rpc('run_forecasts', { t: tenant.id, horizon: 56 });
    setRunning(false);
    if (e) setError(e.message); else loadBase();
  }
  async function createRec(p: Plan) {
    if (!tenant) return;
    setCreating(p.sku_id);
    const { data: rr } = await supabase.rpc('replenish_rationale', { p_sku: p.sku_id });
    const r = (Array.isArray(rr) ? rr[0] : rr) as { qty: number; rationale: string } | undefined;
    const qty = p.suggested_qty || r?.qty || 0;
    const scen = isScenario ? ` [Kịch bản: lead time ${p.lead_time} ngày, an toàn ${p.safety_days} ngày${p90 ? ', dự báo P90' : ''}${!inbound ? ', không tính inbound' : ''}]` : '';
    const { error: e } = await supabase.from('recommendations').insert({
      tenant_id: tenant.id, sku_id: p.sku_id, asin: p.asin, type: 'replenish', title: `Nhập thêm ${qty} đv ${p.asin}`,
      rationale: (r?.rationale ?? `Dự báo ${p.v_fc} đv/ngày, tồn ${p.on_hand}+${p.inbound}, hết hàng ~${p.stockout_date ?? '—'}.`) + scen,
      current_value: p.on_hand, proposed_value: qty, risk_score: 50, status: 'pending_approval',
    });
    setCreating(null);
    if (e) setError(e.message);
  }

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  const cnt = (s: string) => plans.filter((p) => p.status === s).length;
  const list = plans.filter((p) => filter === 'all' || p.status === filter || (filter === 'action' && ['stockout', 'order_now', 'order_soon'].includes(p.status)));
  const chosen = acc.filter((a) => a.chosen_skus > 0);
  const naive = acc.find((a) => a.model === 'naive7');
  const bestMape = chosen.length ? Math.round(chosen.reduce((s, a) => s + (a.avg_mape ?? 0) * a.chosen_skus, 0) / chosen.reduce((s, a) => s + a.chosen_skus, 0) * 10) / 10 : null;
  const lastMade = base.reduce<string | null>((m, p) => (p.made_on && (!m || p.made_on > m) ? p.made_on : m), null);
  const stockValue = plans.reduce((s, p) => s + Number(p.stock_value), 0);
  const selPlan = plans.find((p) => p.sku_id === sel) ?? null;

  return (
    <>
      {/* KPI */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        <Kpi label="Cần đặt hàng" v={cnt('stockout') + cnt('order_now') + cnt('order_soon')} hint={`${cnt('stockout')} hết · ${cnt('order_now')} đặt ngay · ${cnt('order_soon')} đặt sớm`} tone={cnt('stockout') + cnt('order_now') ? 'red' : 'default'} />
        <Kpi label="Tồn dư" v={cnt('overstock')} hint="> 6× nhu cầu lead time + an toàn" tone={cnt('overstock') ? 'amber' : 'default'} />
        <Kpi label="Giá trị tồn (COGS)" v={usd(stockValue, 0)} hint={`${num(plans.reduce((s, p) => s + p.on_hand, 0))} đv on hand · ${num(plans.reduce((s, p) => s + p.inbound, 0))} đang về`} />
        <Card className="p-4">
          <p className="text-xs text-gray-500">Độ chính xác dự báo (gate 7‑8)</p>
          <p className="text-2xl font-bold mt-1 text-gray-900">{bestMape != null ? `MAPE ${bestMape}%` : '—'}</p>
          <p className="text-xs text-gray-500 mt-0.5">{naive?.avg_mape != null ? `naive 7 ngày: ${naive.avg_mape}%` : 'chưa đủ lịch sử để backtest'}{lastMade && ` · lập ${new Date(lastMade).toLocaleDateString('vi-VN')}`}</p>
          {canWrite && <button className={`${btn.ghost} px-0 mt-1`} disabled={running} onClick={runForecast}>{running ? 'Đang chạy…' : 'Chạy forecast ngay →'}</button>}
        </Card>
      </div>

      {/* Scenario planner */}
      <Card className="mb-4">
        <CardHeader title="Kịch bản" subtitle="Thay đổi giả định để xem ngày hết hàng, ngày phải đặt và số lượng đề xuất thay đổi ra sao. Không ghi vào dữ liệu."
          action={isScenario ? <button className={btn.secondary} onClick={() => { setLt(null); setSd(null); setP90(false); setInbound(true); setScen(null); }}>Về mặc định</button> : <span className="text-xs text-gray-500">Đang dùng lead time từng SKU / chính sách</span>} />
        <div className="p-5 grid md:grid-cols-4 gap-5 items-end">
          <Slider label="Lead time" unit="ngày" v={lt} def={pol?.default_lead_time_days ?? 30} min={5} max={120} on={setLt} />
          <Slider label="Tồn kho an toàn" unit="ngày" v={sd} def={pol?.safety_stock_days ?? 14} min={0} max={60} on={setSd} />
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" className="rounded" checked={p90} onChange={(e) => setP90(e.target.checked)} />Dùng dự báo P90 (thận trọng)</label>
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" className="rounded" checked={inbound} onChange={(e) => setInbound(e.target.checked)} />Tính hàng đang về</label>
        </div>
        {isScenario && <p className="px-5 pb-4 text-xs text-indigo-700">{scenLoading ? 'Đang tính lại…' : `Kịch bản: ${list.filter((p) => ['stockout', 'order_now', 'order_soon'].includes(p.status)).length} ASIN cần đặt, tổng ${num(plans.reduce((s, p) => s + p.suggested_qty, 0))} đv đề xuất (mặc định: ${base.filter((p) => ['stockout', 'order_now', 'order_soon'].includes(p.status)).length} ASIN, ${num(base.reduce((s, p) => s + p.suggested_qty, 0))} đv).`}</p>}
      </Card>

      <div className="flex flex-wrap gap-2 mb-3 text-sm">
        {[['all', 'Tất cả'], ['action', 'Cần đặt'], ['overstock', 'Tồn dư'], ['ok', 'Ổn'], ['no_demand', 'Không có cầu']].map(([k, l]) => (
          <button key={k} onClick={() => setFilter(k)} className={`px-3 py-1.5 rounded-lg border ${filter === k ? 'bg-gray-900 text-white border-gray-900' : 'bg-white text-gray-700 border-gray-200 hover:bg-gray-50'}`}>{l}</button>
        ))}
      </div>

      <div className={`grid gap-4 ${selPlan ? 'xl:grid-cols-3' : ''}`}>
        <Card className={selPlan ? 'xl:col-span-2' : ''}>
          {list.length === 0 ? <EmptyState title="Không có ASIN" /> : (
            <Paged items={list} page={LIMITS.tablePage} label="ASIN">{(visible) => (<div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs uppercase text-gray-500 bg-gray-50">
                  <tr>
                    <th className="px-4 py-2 text-left">ASIN</th><th className="px-2 py-2 text-left">Trạng thái</th><th className="px-2 py-2 text-right">Tồn / về</th><th className="px-2 py-2 text-right">Dự báo /ngày</th>
                    <th className="px-2 py-2 text-right">Còn (ngày)</th><th className="px-2 py-2 text-right">Hết hàng</th><th className="px-2 py-2 text-right">Đặt trước</th><th className="px-2 py-2 text-right">Đề xuất</th><th className="px-4 py-2"></th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {visible.map((p) => {
                    const st = STATUS[p.status] ?? STATUS.ok; const b = base.find((x) => x.sku_id === p.sku_id);
                    const late = p.order_by_date && p.order_by_date < new Date().toISOString().slice(0, 10);
                    return (
                      <tr key={p.sku_id} className={`hover:bg-gray-50 cursor-pointer ${sel === p.sku_id ? 'bg-indigo-50/50' : ''}`} onClick={() => setSel(p.sku_id === sel ? null : p.sku_id)}>
                        <td className="px-4 py-2"><span className="font-medium text-gray-900 block max-w-[220px] truncate">{p.title}</span><span className="font-mono text-xs text-gray-500">{p.asin} · LT {p.lead_time}d</span></td>
                        <td className="px-2 py-2"><Badge className={st.cls}>{st.label}</Badge></td>
                        <td className="px-2 py-2 text-right tabular-nums">{num(p.on_hand)}{p.inbound > 0 && <span className="text-gray-400"> +{num(p.inbound)}</span>}</td>
                        <td className="px-2 py-2 text-right tabular-nums">{p.v_fc}{p.mape != null && <span className="block text-[10px] text-gray-400">±{p.mape}%</span>}</td>
                        <td className={`px-2 py-2 text-right tabular-nums font-medium ${p.days_of_cover != null && p.days_of_cover <= p.lead_time ? 'text-red-600' : ''}`}>{p.days_of_cover != null ? Math.round(p.days_of_cover) : '—'}</td>
                        <td className="px-2 py-2 text-right tabular-nums text-gray-600">{p.stockout_date ? fmtD(p.stockout_date) : '—'}</td>
                        <td className={`px-2 py-2 text-right tabular-nums ${late ? 'text-red-600 font-medium' : 'text-gray-600'}`}>{p.order_by_date ? (late ? 'quá hạn' : fmtD(p.order_by_date)) : '—'}</td>
                        <td className="px-2 py-2 text-right tabular-nums font-semibold">{p.suggested_qty > 0 ? num(p.suggested_qty) : '–'}{isScenario && b && b.suggested_qty !== p.suggested_qty && <span className="block text-[10px] text-gray-400">mặc định {num(b.suggested_qty)}</span>}</td>
                        <td className="px-4 py-2 text-right" onClick={(e) => e.stopPropagation()}>
                          {canWrite && p.suggested_qty > 0 && <button className={btn.secondary} disabled={creating === p.sku_id} onClick={() => createRec(p)}>{creating === p.sku_id ? '…' : 'Tạo gợi ý'}</button>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>)}</Paged>
          )}
        </Card>

        {selPlan && <SkuForecastPanel plan={selPlan} onClose={() => setSel(null)} />}
      </div>

      {acc.length > 0 && (
        <Card className="mt-4">
          <CardHeader title="Backtest mô hình dự báo" subtitle="MAPE trung bình trên cửa sổ 7 ngày, 90 ngày gần nhất. Mỗi ASIN tự chọn mô hình tốt nhất." />
          <table className="w-full text-sm">
            <thead className="text-xs uppercase text-gray-500 bg-gray-50"><tr><th className="px-4 py-2 text-left">Mô hình</th><th className="px-2 py-2 text-right">ASIN được chọn</th><th className="px-2 py-2 text-right">MAPE TB</th><th className="px-4 py-2 text-right">Bias TB</th></tr></thead>
            <tbody className="divide-y divide-gray-100">
              {acc.map((a) => (
                <tr key={a.model}><td className="px-4 py-2">{MODEL_LABEL[a.model] ?? a.model}</td><td className="px-2 py-2 text-right tabular-nums">{a.chosen_skus}/{a.skus}</td><td className="px-2 py-2 text-right tabular-nums">{a.avg_mape != null ? `${a.avg_mape}%` : '—'}</td><td className={`px-4 py-2 text-right tabular-nums ${a.avg_bias_pct != null && Math.abs(a.avg_bias_pct) > 15 ? 'text-amber-700' : ''}`}>{a.avg_bias_pct != null ? `${a.avg_bias_pct > 0 ? '+' : ''}${a.avg_bias_pct}%` : '—'}</td></tr>
              ))}
            </tbody>
          </table>
          <p className="px-4 py-3 text-xs text-gray-500 border-t border-gray-100">Gate tuần 7‑8: mô hình được chọn phải có MAPE thấp hơn naive. Bias dương = dự báo cao hơn thực tế (dễ tồn dư).</p>
        </Card>
      )}
    </>
  );
}

function SkuForecastPanel({ plan, onClose }: { plan: Plan; onClose: () => void }) {
  const [pts, setPts] = React.useState<ForecastPoint[]>([]);
  React.useEffect(() => {
    (async () => {
      const since = new Date(Date.now() - 56 * 86400000).toISOString().slice(0, 10);
      const [h, f] = await Promise.all([
        supabase.from('sku_daily_snapshots').select('date,units').eq('sku_id', plan.sku_id).gte('date', since).order('date').limit(LIMITS.chartDays),
        plan.made_on ? supabase.from('forecasts').select('date,p50,p90').eq('sku_id', plan.sku_id).eq('made_on', plan.made_on).order('date') : Promise.resolve({ data: [] }),
      ]);
      const map = new Map<string, ForecastPoint>();
      ((h.data ?? []) as { date: string; units: number | null }[]).forEach((r) => map.set(r.date, { date: r.date, actual: r.units }));
      ((f.data ?? []) as { date: string; p50: number; p90: number }[]).forEach((r) => map.set(r.date, { ...(map.get(r.date) ?? { date: r.date }), p50: Number(r.p50), p90: Number(r.p90) }));
      setPts([...map.values()].sort((a, b) => a.date.localeCompare(b.date)));
    })();
  }, [plan.sku_id, plan.made_on]);
  const st = STATUS[plan.status] ?? STATUS.ok;
  return (
    <Card className="self-start">
      <CardHeader title={plan.asin} subtitle={plan.title} action={<button className={btn.ghost} onClick={onClose}>✕</button>} />
      <div className="p-4 space-y-3 text-sm">
        <div className="flex flex-wrap gap-2 items-center"><Badge className={st.cls}>{st.label}</Badge><span className="text-xs text-gray-500">Mô hình: {plan.model ? MODEL_LABEL[plan.model] ?? plan.model : '—'}{plan.mape != null && ` · MAPE ${plan.mape}%`}</span></div>
        <ForecastChart data={pts} />
        <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
          <dt className="text-gray-500">Tồn / đang về</dt><dd className="text-right tabular-nums">{num(plan.on_hand)} / {num(plan.inbound)}</dd>
          <dt className="text-gray-500">Nhu cầu trong lead time + an toàn</dt><dd className="text-right tabular-nums">{num(plan.demand_lead)} đv ({plan.lead_time}+{plan.safety_days} ngày)</dd>
          <dt className="text-gray-500">Hết hàng dự kiến</dt><dd className="text-right">{plan.stockout_date ? fmtD(plan.stockout_date) : '—'}</dd>
          <dt className="text-gray-500">Phải đặt trước</dt><dd className="text-right">{plan.order_by_date ? fmtD(plan.order_by_date) : '—'}</dd>
          <dt className="text-gray-500">Mục tiêu phủ</dt><dd className="text-right">{plan.target_cover_days} ngày</dd>
          <dt className="text-gray-500">Đề xuất nhập</dt><dd className="text-right font-semibold">{plan.suggested_qty > 0 ? `${num(plan.suggested_qty)} đv` : '—'}</dd>
          {plan.overstock_days != null && <><dt className="text-gray-500">Vượt ngưỡng tồn dư</dt><dd className="text-right text-indigo-700">{num(plan.overstock_days)} ngày</dd></>}
        </dl>
        <p className="text-xs text-gray-500">Đề xuất = nhu cầu dự báo {plan.target_cover_days} ngày (lead time + an toàn + chu kỳ 28 ngày) − (tồn + đang về).</p>
        <Link href={`/skus/${plan.sku_id}`} className={btn.secondary}>Chi tiết ASIN →</Link>
      </div>
    </Card>
  );
}

function Slider({ label, unit, v, def, min, max, on }: { label: string; unit: string; v: number | null; def: number; min: number; max: number; on: (n: number | null) => void }) {
  const val = v ?? def;
  return (
    <div>
      <div className="flex justify-between text-xs mb-1"><span className="font-medium text-gray-700">{label}</span><span className="tabular-nums">{val} {unit}{v == null && <span className="text-gray-400"> (mặc định)</span>}</span></div>
      <input type="range" min={min} max={max} value={val} onChange={(e) => on(Number(e.target.value))} className="w-full accent-indigo-600" />
    </div>
  );
}
function Kpi({ label, v, hint, tone }: { label: string; v: React.ReactNode; hint?: string; tone?: 'red' | 'amber' | 'default' }) {
  return <Card className="p-4"><p className="text-xs text-gray-500">{label}</p><p className={`text-2xl font-bold mt-1 ${tone === 'red' ? 'text-red-600' : tone === 'amber' ? 'text-amber-700' : 'text-gray-900'}`}>{v}</p>{hint && <p className="text-xs text-gray-500 mt-0.5">{hint}</p>}</Card>;
}
const fmtD = (d: string) => new Date(d).toLocaleDateString('vi-VN', { day: '2-digit', month: '2-digit' });
function numify(p: Plan): Plan {
  const o = { ...p } as Record<string, unknown>;
  for (const k of ['on_hand', 'inbound', 'lead_time', 'safety_days', 'mape', 'v_fc', 'demand_lead', 'days_of_cover', 'target_cover_days', 'suggested_qty', 'stock_value', 'overstock_days']) if (o[k] != null) o[k] = Number(o[k]);
  return o as unknown as Plan;
}
