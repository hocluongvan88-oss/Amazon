'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { usd, num } from '@/lib/format';
import { Card, CardHeader, Badge, btn, input } from '@/components/ui';

type Check = { id: string; period_start: string; period_end: string; sc_revenue: number; sc_units: number; sys_revenue: number; sys_units: number; revenue_diff_pct: number | null; units_diff_pct: number | null; tolerance_pct: number; passed: boolean; created_at: string; note: string | null };

const iso = (d: Date) => d.toISOString().slice(0, 10);

export default function Reconciliation() {
  const { tenant, can } = useTenant();
  const canWrite = can('data.import');
  const [list, setList] = React.useState<Check[]>([]);
  const [start, setStart] = React.useState(() => iso(new Date(Date.now() - 30 * 86400000)));
  const [end, setEnd] = React.useState(() => iso(new Date(Date.now() - 86400000)));
  const [rev, setRev] = React.useState('');
  const [units, setUnits] = React.useState('');
  const [note, setNote] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const { data } = await supabase.from('reconciliation_checks').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(8);
    setList((data ?? []) as Check[]);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function run(e: React.FormEvent) {
    e.preventDefault();
    if (!tenant) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc('run_reconciliation', { t: tenant.id, p_start: start, p_end: end, p_sc_revenue: Number(rev), p_sc_units: Number(units), p_note: note || null });
    setBusy(false);
    if (error) setErr(error.message); else { setRev(''); setUnits(''); setNote(''); load(); }
  }

  return (
    <Card id="recon">
      <CardHeader title="Đối soát với Seller Central" subtitle="Nhập tổng Ordered Product Sales & Units Ordered của Business Report cho cùng khoảng ngày; hệ thống so với dữ liệu đã nhập. Đạt khi lệch ≤ tolerance trong Chính sách." />
      <div className="p-5 grid lg:grid-cols-2 gap-6">
        {canWrite && (
          <form onSubmit={run} className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <L label="Từ ngày"><input type="date" value={start} onChange={(e) => setStart(e.target.value)} className={input} required /></L>
              <L label="Đến ngày"><input type="date" value={end} onChange={(e) => setEnd(e.target.value)} className={input} required /></L>
              <L label="Doanh thu theo Seller Central (USD)"><input type="number" step="0.01" min="0" value={rev} onChange={(e) => setRev(e.target.value)} className={input} required /></L>
              <L label="Đơn vị theo Seller Central"><input type="number" step="1" min="0" value={units} onChange={(e) => setUnits(e.target.value)} className={input} required /></L>
            </div>
            <L label="Ghi chú"><input value={note} onChange={(e) => setNote(e.target.value)} className={input} placeholder="VD: Business Report 1–30/8, tải 10/9" /></L>
            {err && <p className="text-sm text-red-600">{err}</p>}
            <button className={btn.primary} disabled={busy}>{busy ? 'Đang so…' : 'Chạy đối soát'}</button>
            <p className="text-xs text-gray-500">Mẹo: dùng khoảng ≥ 7 ngày để triệt tiêu lệch múi giờ giữa file đơn hàng (UTC) và báo cáo.</p>
          </form>
        )}
        <div>
          <p className="text-sm font-medium text-gray-900 mb-2">Lịch sử</p>
          {list.length === 0 ? <p className="text-sm text-gray-500">Chưa có lần đối soát nào.</p> : (
            <ul className="divide-y divide-gray-100 border border-gray-200 rounded-lg">
              {list.map((c) => (
                <li key={c.id} className="px-3 py-2 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-gray-900">{new Date(c.period_start).toLocaleDateString('vi-VN')} – {new Date(c.period_end).toLocaleDateString('vi-VN')}</span>
                    {c.passed ? <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-600/20">Đạt</Badge> : <Badge className="bg-red-50 text-red-700 ring-red-600/20">Lệch</Badge>}
                  </div>
                  <p className="text-xs text-gray-500">
                    DT: hệ thống {usd(c.sys_revenue, 0)} vs SC {usd(c.sc_revenue, 0)} ({c.revenue_diff_pct ?? '—'}%) · ĐV: {num(c.sys_units)} vs {num(c.sc_units)} ({c.units_diff_pct ?? '—'}%) · tol ±{c.tolerance_pct}%
                  </p>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </Card>
  );
}
function L({ label, children }: { label: string; children: React.ReactNode }) {
  return <div><label className="block text-xs font-medium text-gray-700 mb-1">{label}</label>{children}</div>;
}
