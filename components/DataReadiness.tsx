'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { usd } from '@/lib/format';
import { Card, CardHeader, Badge, btn } from '@/components/ui';

type Readiness = {
  sku_total: number; sku_ready: number; missing_cogs: number; missing_fba_fee: number; missing_referral: number;
  missing_lead_time: number; no_sales_data: number; revenue_total: number; revenue_ready: number;
  readiness_pct: number; target_pct: number; gate_passed: boolean;
};
type Baseline = { captured_at: string; contribution_profit: number; revenue: number; data_readiness_pct: number | null };

export default function DataReadiness() {
  const { tenant, canWrite } = useTenant();
  const [r, setR] = React.useState<Readiness | null>(null);
  const [b, setB] = React.useState<Baseline | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [rd, bl] = await Promise.all([
      supabase.from('v_data_readiness').select('*').eq('tenant_id', tenant.id).maybeSingle(),
      supabase.from('kpi_baseline').select('captured_at,contribution_profit,revenue,data_readiness_pct').eq('tenant_id', tenant.id).eq('is_active', true).order('captured_at', { ascending: false }).limit(1).maybeSingle(),
    ]);
    setR((rd.data as Readiness) ?? null);
    setB((bl.data as Baseline) ?? null);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function capture() {
    if (!tenant) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc('capture_kpi_baseline', { t: tenant.id, lbl: 'baseline' });
    setBusy(false);
    if (error) setMsg(error.message); else { setMsg('Đã chốt baseline.'); load(); }
  }

  if (!r) return null;
  const pct = Number(r.readiness_pct);
  const tone = r.gate_passed ? 'emerald' : pct >= 60 ? 'amber' : 'red';
  const bar = { emerald: 'bg-emerald-500', amber: 'bg-amber-500', red: 'bg-red-500' }[tone];
  const gaps: [string, number][] = [
    ['thiếu COGS', r.missing_cogs], ['thiếu phí FBA', r.missing_fba_fee], ['thiếu referral %', r.missing_referral],
    ['thiếu lead time', r.missing_lead_time], ['chưa có doanh số', r.no_sales_data],
  ];

  return (
    <Card>
      <CardHeader
        title="Gate tuần 1–2: sẵn sàng dữ liệu"
        subtitle={`Mục tiêu: ≥ ${Number(r.target_pct).toFixed(0)}% doanh thu 30 ngày có đủ COGS + phí để tính lợi nhuận góp phần`}
        action={r.gate_passed
          ? <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-600/20">✓ Đạt gate</Badge>
          : <Badge className="bg-red-50 text-red-700 ring-red-600/20">Chưa đạt</Badge>}
      />
      <div className="p-5 grid md:grid-cols-3 gap-6">
        <div className="md:col-span-2">
          <div className="flex items-end justify-between mb-1">
            <span className="text-3xl font-bold text-gray-900 tabular-nums">{pct.toFixed(1)}%</span>
            <span className="text-sm text-gray-500">{usd(r.revenue_ready, 0)} / {usd(r.revenue_total, 0)} doanh thu · {r.sku_ready}/{r.sku_total} SKU</span>
          </div>
          <div className="h-2.5 rounded-full bg-gray-200 overflow-hidden relative">
            <div className={`h-full ${bar}`} style={{ width: `${Math.min(100, pct)}%` }} />
            <div className="absolute top-0 bottom-0 w-0.5 bg-gray-700" style={{ left: `${Number(r.target_pct)}%` }} title="Mục tiêu" />
          </div>
          <ul className="mt-3 flex flex-wrap gap-2 text-xs">
            {gaps.filter(([, n]) => n > 0).map(([l, n]) => (
              <li key={l} className="px-2 py-1 rounded-md bg-gray-100 text-gray-700">{n} SKU {l}</li>
            ))}
            {gaps.every(([, n]) => n === 0) && <li className="text-emerald-700">Không thiếu trường nào.</li>}
          </ul>
          {canWrite && (
            <div className="mt-3 flex flex-wrap gap-2">
              <Link href="/import" className={btn.primary}>Nhập CSV</Link>
              <Link href="/settings/policy" className={btn.secondary}>Chính sách</Link>
            </div>
          )}
        </div>
        <div className="border-t md:border-t-0 md:border-l border-gray-100 pt-4 md:pt-0 md:pl-6">
          <p className="text-sm font-medium text-gray-900">Baseline KPI</p>
          {b ? (
            <div className="mt-1 text-sm text-gray-600 space-y-0.5">
              <p>Chốt {new Date(b.captured_at).toLocaleDateString('vi-VN')}</p>
              <p>CP 30 ngày: <b className="text-gray-900">{usd(b.contribution_profit, 0)}</b></p>
              <p>Doanh thu: {usd(b.revenue, 0)}</p>
              {b.data_readiness_pct != null && <p>Sẵn sàng dữ liệu lúc chốt: {Number(b.data_readiness_pct).toFixed(0)}%</p>}
            </div>
          ) : (
            <p className="mt-1 text-sm text-gray-500">Chưa chốt. Baseline là mốc để đo incremental contribution cuối pilot.</p>
          )}
          {canWrite && (
            <button className={`${btn.secondary} mt-3`} disabled={busy} onClick={capture} title={!r.gate_passed ? 'Nên đạt gate trước khi chốt' : ''}>
              {busy ? 'Đang chốt…' : b ? 'Chốt lại baseline' : 'Chốt baseline'}
            </button>
          )}
          {msg && <p className="mt-2 text-xs text-gray-600">{msg}</p>}
        </div>
      </div>
    </Card>
  );
}
