'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, EmptyState, Spinner, ErrorBox } from '@/components/ui';
import { WaterfallChart, type WaterfallStep } from '@/components/charts';
import { usd as fmtMoney } from '@/lib/format';

type Row = {
  sku_id: string; asin: string; title: string; units0: number; units1: number; cp0: number; cp1: number; delta: number;
  d_volume: number; d_price: number; d_cogs: number; d_fees: number; d_ads: number; cov0: number; cov1: number;
};
const DRIVERS: { k: keyof Row; label: string; hint: string }[] = [
  { k: 'd_volume', label: 'Sản lượng', hint: 'Bán nhiều/ít hơn ở cùng biên đơn vị kỳ trước' },
  { k: 'd_price', label: 'Giá bán', hint: 'Giá thay đổi (đã trừ phí giới thiệu theo %)' },
  { k: 'd_cogs', label: 'Giá vốn', hint: 'COGS/đơn vị thay đổi' },
  { k: 'd_fees', label: 'Phí Amazon', hint: 'FBA/fulfilment fee mỗi đơn vị' },
  { k: 'd_ads', label: 'Quảng cáo', hint: 'Chi tiêu quảng cáo tuyệt đối' },
];

export default function ProfitBridge() {
  const { tenant } = useTenant();
  const [days, setDays] = React.useState(14);
  const [rows, setRows] = React.useState<Row[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [sortKey, setSortKey] = React.useState<'delta' | 'abs'>('abs');

  React.useEffect(() => {
    if (!tenant) return;
    (async () => {
      setLoading(true);
      const { data, error: e } = await supabase.rpc('profit_bridge', { t: tenant.id, days });
      if (e) setError(e.message); else setRows(((data ?? []) as Row[]).map((r) => ({ ...r, ...Object.fromEntries(Object.entries(r).map(([k, v]) => [k, typeof v === 'string' && !isNaN(Number(v)) && k !== 'asin' && k !== 'title' && k !== 'sku_id' ? Number(v) : v])) })) as Row[]);
      setLoading(false);
    })();
  }, [tenant, days]);

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  const sum = (k: keyof Row) => rows.reduce((a, r) => a + (Number(r[k]) || 0), 0);
  const cp0 = sum('cp0'), cp1 = sum('cp1');
  const steps: WaterfallStep[] = [
    { name: `Kỳ trước`, value: cp0, kind: 'total' },
    ...DRIVERS.map((d) => ({ name: d.label, value: sum(d.k), kind: 'delta' as const })),
    { name: `Kỳ này`, value: cp1, kind: 'total' },
  ];
  const sorted = [...rows].sort((a, b) => (sortKey === 'abs' ? Math.abs(b.delta) - Math.abs(a.delta) : a.delta - b.delta));
  const lowCov = rows.filter((r) => r.cov0 < days * 0.7 || r.cov1 < days * 0.7).length;

  return (
    <>
      <div className="flex flex-wrap items-center gap-2 mb-4">
        {[7, 14, 28].map((d) => (
          <button key={d} onClick={() => setDays(d)} className={`px-3 py-1.5 rounded-lg text-sm border ${days === d ? 'bg-gray-900 text-white border-gray-900' : 'bg-white text-gray-700 border-gray-200 hover:bg-gray-50'}`}>{d} ngày</button>
        ))}
        <span className="text-sm text-gray-500 ml-2">So {days} ngày gần nhất với {days} ngày trước đó · nguồn: snapshot ngày</span>
      </div>

      {rows.length === 0 ? <EmptyState title="Chưa đủ snapshot" description="Cần ít nhất vài ngày snapshot ở cả hai kỳ. Nhập dữ liệu ngày hoặc chờ snapshot tự động." /> : (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
            <Kpi label="CP kỳ trước" v={fmtMoney(cp0)} />
            <Kpi label="CP kỳ này" v={fmtMoney(cp1)} />
            <Kpi label="Chênh lệch" v={`${cp1 - cp0 >= 0 ? '+' : ''}${fmtMoney(cp1 - cp0)}`} tone={cp1 - cp0 >= 0 ? 'green' : 'red'} />
            <Kpi label="Yếu tố lớn nhất" v={(() => { const m = DRIVERS.map((d) => ({ d, v: sum(d.k) })).sort((a, b) => Math.abs(b.v) - Math.abs(a.v))[0]; return m ? `${m.d.label} ${m.v >= 0 ? '+' : ''}${fmtMoney(m.v)}` : '—'; })()} />
          </div>

          <Card className="mb-4">
            <CardHeader title="Cầu lợi nhuận toàn tài khoản" subtitle="Các bậc cộng lại đúng bằng chênh lệch (phân rã tuần tự: sản lượng → giá → giá vốn → phí → quảng cáo)" />
            <div className="p-4"><WaterfallChart steps={steps} /></div>
            <div className="px-5 pb-4 grid sm:grid-cols-5 gap-2 text-xs text-gray-500">
              {DRIVERS.map((d) => <div key={d.k}><b className="text-gray-700">{d.label}:</b> {d.hint}</div>)}
            </div>
          </Card>

          {lowCov > 0 && <p className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-4">{lowCov} SKU có ít hơn 70% ngày snapshot ở một trong hai kỳ — số liệu các SKU này chỉ mang tính tham khảo.</p>}

          <Card>
            <CardHeader title="Theo ASIN" subtitle="Ai kéo lợi nhuận lên, ai kéo xuống" action={
              <select value={sortKey} onChange={(e) => setSortKey(e.target.value as 'delta' | 'abs')} className="text-sm border border-gray-200 rounded-lg px-2 py-1">
                <option value="abs">Ảnh hưởng lớn nhất</option><option value="delta">Giảm nhiều nhất</option>
              </select>} />
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-xs uppercase text-gray-500 bg-gray-50">
                  <tr>
                    <th className="px-4 py-2 text-left">SKU</th><th className="px-2 py-2 text-right">Units</th><th className="px-2 py-2 text-right">CP trước → nay</th><th className="px-2 py-2 text-right">Δ</th>
                    {DRIVERS.map((d) => <th key={d.k} className="px-2 py-2 text-right">{d.label}</th>)}<th className="px-4 py-2 text-right">Ngày dữ liệu</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {sorted.map((r) => (
                    <tr key={r.sku_id} className="hover:bg-gray-50">
                      <td className="px-4 py-2"><Link href={`/skus/${r.sku_id}`} className="hover:underline"><span className="font-mono text-xs text-gray-500">{r.asin}</span><br />{r.title}</Link></td>
                      <td className="px-2 py-2 text-right tabular-nums text-gray-600">{r.units0} → {r.units1}</td>
                      <td className="px-2 py-2 text-right tabular-nums text-gray-600">{fmtMoney(r.cp0)} → {fmtMoney(r.cp1)}</td>
                      <td className={`px-2 py-2 text-right tabular-nums font-semibold ${r.delta >= 0 ? 'text-emerald-700' : 'text-red-600'}`}>{r.delta >= 0 ? '+' : ''}{fmtMoney(r.delta)}</td>
                      {DRIVERS.map((d) => { const v = Number(r[d.k]); return <td key={d.k} className={`px-2 py-2 text-right tabular-nums ${Math.abs(v) < 0.5 ? 'text-gray-400' : v > 0 ? 'text-emerald-700' : 'text-red-600'}`}>{Math.abs(v) < 0.5 ? '–' : `${v > 0 ? '+' : ''}${fmtMoney(v)}`}</td>; })}
                      <td className="px-4 py-2 text-right tabular-nums text-xs text-gray-500">{r.cov0}/{r.cov1}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
        </>
      )}
    </>
  );
}

function Kpi({ label, v, tone }: { label: string; v: string; tone?: 'green' | 'red' }) {
  return <Card className="p-4"><p className="text-xs text-gray-500">{label}</p><p className={`text-xl font-bold mt-1 ${tone === 'green' ? 'text-emerald-700' : tone === 'red' ? 'text-red-600' : 'text-gray-900'}`}>{v}</p></Card>;
}
