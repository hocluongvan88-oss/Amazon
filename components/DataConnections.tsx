'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, btn } from '@/components/ui';

type Conn = {
  last_state_snapshot: string | null; last_sales_date: string | null; last_ads_date: string | null;
  sales_days_30: number; ads_days_30: number; last_orders_import: string | null; last_ads_import: string | null;
  last_other_import: string | null; last_recon_passed: boolean | null; last_recon_at: string | null; coverage_revenue_pct: number;
};

const daysAgo = (d: string | null) => (d ? Math.floor((Date.now() - new Date(d).getTime()) / 86400000) : null);
const fmt = (d: string | null) => (d ? new Date(d).toLocaleDateString('vi-VN') : 'chưa có');

export default function DataConnections({ compact = false }: { compact?: boolean }) {
  const { tenant, canWrite } = useTenant();
  const [c, setC] = React.useState<Conn | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const { data } = await supabase.from('v_data_connections').select('*').eq('tenant_id', tenant.id).maybeSingle();
    setC((data as Conn) ?? null);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function snap() {
    if (!tenant) return;
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc('capture_daily_snapshots', { t: tenant.id, d: new Date().toISOString().slice(0, 10), src: 'manual' });
    setBusy(false);
    if (error) setMsg(error.message); else { setMsg(`Đã chụp ${data} SKU.`); load(); }
  }

  if (!c) return null;
  const stateAge = daysAgo(c.last_state_snapshot);
  const stateOk = stateAge != null && stateAge <= 2;
  const covOk = Number(c.coverage_revenue_pct) >= 90;
  const reconAge = daysAgo(c.last_recon_at);
  const reconOk = c.last_recon_passed === true && reconAge != null && reconAge <= 14;
  const gate = stateOk && covOk && reconOk;

  return (
    <Card>
      <CardHeader title="Kết nối dữ liệu & gate tuần 3–4" subtitle="Snapshot hằng ngày · dữ liệu bán theo ngày · đối soát với Seller Central"
        action={gate ? <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-600/20">✓ Đạt gate</Badge> : <Badge className="bg-yellow-50 text-yellow-800 ring-yellow-600/20">Đang hoàn thiện</Badge>} />
      <div className={`p-5 grid ${compact ? '' : 'md:grid-cols-2'} gap-5`}>
        <ul className="space-y-2">
          <Row ok={stateOk} label="Snapshot trạng thái" detail={c.last_state_snapshot ? `gần nhất ${fmt(c.last_state_snapshot)} (${stateAge} ngày trước)` : 'chưa chạy'} />
          <Row ok={covOk} label="Dữ liệu bán theo ngày" detail={`${c.sales_days_30}/30 ngày · ${Number(c.coverage_revenue_pct).toFixed(0)}% doanh thu có ≥20 ngày (mục tiêu 90%)`} />
          <Row ok={c.ads_days_30 > 0 ? true : null} label="Quảng cáo theo ngày" detail={c.ads_days_30 > 0 ? `${c.ads_days_30}/30 ngày, tới ${fmt(c.last_ads_date)}` : 'chưa nhập (tuỳ chọn)'} />
          <Row ok={c.last_recon_at ? reconOk : null} label="Đối soát Seller Central" detail={c.last_recon_at ? `${c.last_recon_passed ? 'đạt' : 'không đạt'} · ${fmt(c.last_recon_at)}` : 'chưa thực hiện'} />
          <Row ok={null} label="SP‑API" detail="chưa kết nối – đang dùng CSV export (hợp lệ cho pilot)" />
        </ul>
        {canWrite && (
          <div className="flex flex-col gap-2 items-start">
            <div className="flex flex-wrap gap-2">
              <button className={btn.secondary} disabled={busy} onClick={snap}>{busy ? 'Đang chụp…' : 'Chụp snapshot hôm nay'}</button>
              <Link href="/import" className={btn.primary}>Nhập đơn hàng / QC</Link>
              <Link href="/import#recon" className={btn.secondary}>Đối soát</Link>
            </div>
            {msg && <p className="text-xs text-gray-600">{msg}</p>}
            <p className="text-xs text-gray-500">Lịch tự động 03:00 UTC cần extension <code>pg_cron</code> (Supabase → Database → Extensions). Nếu chưa bật, chụp tay mỗi ngày.</p>
          </div>
        )}
      </div>
    </Card>
  );
}

function Row({ ok, label, detail }: { ok: boolean | null; label: string; detail: string }) {
  return (
    <li className="flex items-start gap-2 text-sm">
      <span className={`mt-0.5 h-2 w-2 rounded-full shrink-0 ${ok == null ? 'bg-gray-300' : ok ? 'bg-emerald-500' : 'bg-red-500'}`} />
      <div><span className="text-gray-900">{label}</span> <span className="text-gray-500">· {detail}</span></div>
    </li>
  );
}
