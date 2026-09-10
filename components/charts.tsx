'use client';

import React from 'react';
import {
  ResponsiveContainer, ComposedChart, LineChart, BarChart, Line, Bar, Area, Cell, XAxis, YAxis, Tooltip, CartesianGrid, Legend, ReferenceLine,
} from 'recharts';

const fmtDate = (d: string) => { const x = new Date(d); return `${x.getDate()}/${x.getMonth() + 1}`; };
const fmtUsd = (v: number) => `$${Math.round(v).toLocaleString('en-US')}`;
const fmtNum = (v: number) => Math.round(v).toLocaleString('vi-VN');

export type DailyPoint = {
  date: string; units?: number | null; revenue?: number | null; cp?: number | null; ad_spend?: number | null;
  price?: number | null; contribution_profit?: number | null; inventory_qty?: number | null; reorder_point?: number | null;
  ma7?: number | null; tacos?: number | null;
};

const tooltipStyle = { fontSize: 12, borderRadius: 8, border: '1px solid #e5e7eb' };

export function RevenueProfitChart({ data, height = 240 }: { data: DailyPoint[]; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <ComposedChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis dataKey="date" tickFormatter={fmtDate} tick={{ fontSize: 11 }} minTickGap={24} />
        <YAxis yAxisId="usd" tickFormatter={fmtUsd} tick={{ fontSize: 11 }} width={56} />
        <YAxis yAxisId="units" orientation="right" tickFormatter={fmtNum} tick={{ fontSize: 11 }} width={40} />
        <Tooltip contentStyle={tooltipStyle} labelFormatter={(l) => new Date(String(l)).toLocaleDateString('vi-VN')}
          formatter={(v, name) => [typeof v === 'number' ? (name === 'Đơn vị' ? fmtNum(v) : fmtUsd(v)) : '—', name]} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        <Bar yAxisId="units" dataKey="units" name="Đơn vị" fill="#c7d2fe" radius={[2, 2, 0, 0]} />
        <Line yAxisId="usd" type="monotone" dataKey="revenue" name="Doanh thu" stroke="#4f46e5" strokeWidth={2} dot={false} connectNulls />
        <Line yAxisId="usd" type="monotone" dataKey="cp" name="LN góp phần" stroke="#059669" strokeWidth={2} dot={false} connectNulls />
      </ComposedChart>
    </ResponsiveContainer>
  );
}

export function UnitsChart({ data, height = 200 }: { data: DailyPoint[]; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <ComposedChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis dataKey="date" tickFormatter={fmtDate} tick={{ fontSize: 11 }} minTickGap={24} />
        <YAxis tick={{ fontSize: 11 }} width={36} allowDecimals={false} />
        <Tooltip contentStyle={tooltipStyle} labelFormatter={(l) => new Date(String(l)).toLocaleDateString('vi-VN')} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        <Bar dataKey="units" name="Đơn vị/ngày" fill="#a5b4fc" radius={[2, 2, 0, 0]} />
        <Line type="monotone" dataKey="ma7" name="TB 7 ngày" stroke="#4f46e5" strokeWidth={2} dot={false} connectNulls />
      </ComposedChart>
    </ResponsiveContainer>
  );
}

export function PriceProfitChart({ data, height = 200 }: { data: DailyPoint[]; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis dataKey="date" tickFormatter={fmtDate} tick={{ fontSize: 11 }} minTickGap={24} />
        <YAxis tick={{ fontSize: 11 }} width={44} tickFormatter={(v) => `$${v}`} domain={['auto', 'auto']} />
        <Tooltip contentStyle={tooltipStyle} labelFormatter={(l) => new Date(String(l)).toLocaleDateString('vi-VN')} formatter={(v) => (typeof v === 'number' ? `$${v.toFixed(2)}` : '—')} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        <Line type="stepAfter" dataKey="price" name="Giá" stroke="#4f46e5" strokeWidth={2} dot={false} connectNulls />
        <Line type="stepAfter" dataKey="contribution_profit" name="LN góp phần / đv" stroke="#059669" strokeWidth={2} dot={false} connectNulls />
      </LineChart>
    </ResponsiveContainer>
  );
}

export function InventoryChart({ data, reorderPoint, eta, height = 200 }: { data: DailyPoint[]; reorderPoint?: number | null; eta?: string | null; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <ComposedChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis dataKey="date" tickFormatter={fmtDate} tick={{ fontSize: 11 }} minTickGap={24} />
        <YAxis tick={{ fontSize: 11 }} width={44} tickFormatter={fmtNum} />
        <Tooltip contentStyle={tooltipStyle} labelFormatter={(l) => new Date(String(l)).toLocaleDateString('vi-VN')} formatter={(v) => (typeof v === 'number' ? fmtNum(v) : '—')} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        <Area type="stepAfter" dataKey="inventory_qty" name="Tồn kho" stroke="#0ea5e9" fill="#e0f2fe" strokeWidth={2} connectNulls />
        {reorderPoint != null && reorderPoint > 0 && <ReferenceLine y={reorderPoint} stroke="#f59e0b" strokeDasharray="4 4" label={{ value: `ROP ${reorderPoint}`, fontSize: 11, fill: '#b45309', position: 'insideTopRight' }} />}
        {eta && <ReferenceLine x={eta} stroke="#dc2626" strokeDasharray="4 4" label={{ value: 'ETA hết hàng', fontSize: 11, fill: '#b91c1c', position: 'insideTopLeft' }} />}
      </ComposedChart>
    </ResponsiveContainer>
  );
}

export function AdsChart({ data, height = 200 }: { data: DailyPoint[]; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <ComposedChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" />
        <XAxis dataKey="date" tickFormatter={fmtDate} tick={{ fontSize: 11 }} minTickGap={24} />
        <YAxis yAxisId="usd" tick={{ fontSize: 11 }} width={48} tickFormatter={fmtUsd} />
        <YAxis yAxisId="pct" orientation="right" tick={{ fontSize: 11 }} width={40} tickFormatter={(v) => `${v}%`} />
        <Tooltip contentStyle={tooltipStyle} labelFormatter={(l) => new Date(String(l)).toLocaleDateString('vi-VN')} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        <Bar yAxisId="usd" dataKey="ad_spend" name="Chi phí QC" fill="#fecaca" radius={[2, 2, 0, 0]} />
        <Line yAxisId="pct" type="monotone" dataKey="tacos" name="TACoS %" stroke="#dc2626" strokeWidth={2} dot={false} connectNulls />
      </ComposedChart>
    </ResponsiveContainer>
  );
}

/** Thêm MA7 & TACoS vào chuỗi ngày */
export function enrich(points: DailyPoint[]): DailyPoint[] {
  return points.map((p, i) => {
    const win = points.slice(Math.max(0, i - 6), i + 1).map((x) => x.units).filter((u): u is number => u != null);
    const ma7 = win.length ? win.reduce((a, b) => a + b, 0) / win.length : null;
    const tacos = p.ad_spend != null && p.revenue ? Math.round((1000 * p.ad_spend) / p.revenue) / 10 : null;
    return { ...p, ma7: ma7 == null ? null : Math.round(ma7 * 10) / 10, tacos };
  });
}

export function fillDays(rows: DailyPoint[], days: number): DailyPoint[] {
  const by = new Map(rows.map((r) => [r.date, r]));
  const out: DailyPoint[] = [];
  const today = new Date(); today.setUTCHours(0, 0, 0, 0);
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(today); d.setUTCDate(d.getUTCDate() - i);
    const key = d.toISOString().slice(0, 10);
    out.push(by.get(key) ?? { date: key });
  }
  return out;
}

/* ---------- Waterfall (profit bridge) ---------- */
function buildWaterfall(steps: WaterfallStep[]) {
  const out: { name: string; base: number; bar: number; signed: number; kind: 'total' | 'delta' }[] = [];
  let running = 0;
  for (const s of steps) {
    if (s.kind === 'total') { running = s.value; out.push({ name: s.name, base: Math.min(0, s.value), bar: Math.abs(s.value), signed: s.value, kind: s.kind }); continue; }
    const start = running; running += s.value;
    out.push({ name: s.name, base: Math.min(start, running), bar: Math.abs(s.value), signed: s.value, kind: s.kind });
  }
  return out;
}
export type WaterfallStep = { name: string; value: number; kind: 'total' | 'delta' };

export function WaterfallChart({ steps, height = 260 }: { steps: WaterfallStep[]; height?: number }) {
  const data = buildWaterfall(steps);
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" />
        <XAxis dataKey="name" tick={{ fontSize: 12 }} />
        <YAxis tickFormatter={fmtUsd} tick={{ fontSize: 11 }} width={64} />
        <Tooltip contentStyle={tooltipStyle} formatter={(_v, _n, p) => { const d = p.payload as { signed: number; kind: string }; return [`${d.kind === 'delta' && d.signed > 0 ? '+' : ''}${fmtUsd(d.signed)}`, d.kind === 'total' ? 'Lợi nhuận đóng góp' : 'Tác động']; }} />
        <ReferenceLine y={0} stroke="#9ca3af" />
        <Bar dataKey="base" stackId="w" fill="transparent" isAnimationActive={false} />
        <Bar dataKey="bar" stackId="w" radius={[3, 3, 0, 0]} isAnimationActive={false}>
          {data.map((d, i) => <Cell key={i} fill={d.kind === 'total' ? '#111827' : d.signed >= 0 ? '#059669' : '#dc2626'} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}

/* ---------- Risk history ---------- */
export function RiskHistoryChart({ data, height = 160 }: { data: { date: string; risk_score: number }[]; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" />
        <XAxis dataKey="date" tickFormatter={fmtDate} tick={{ fontSize: 11 }} />
        <YAxis domain={[0, 100]} tick={{ fontSize: 11 }} width={32} />
        <Tooltip contentStyle={tooltipStyle} labelFormatter={(l) => `Ngày ${fmtDate(String(l))}`} formatter={(v) => [`${v}`, 'Điểm rủi ro']} />
        <ReferenceLine y={70} stroke="#dc2626" strokeDasharray="4 4" />
        <ReferenceLine y={40} stroke="#f59e0b" strokeDasharray="4 4" />
        <Line type="monotone" dataKey="risk_score" stroke="#7c3aed" strokeWidth={2} dot={false} />
      </LineChart>
    </ResponsiveContainer>
  );
}
