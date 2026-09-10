'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { usd, num, riskLevel, RISK_META, REC_TYPE_LABEL } from '@/lib/format';
import { Card, CardHeader, Badge, StatCard, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';
import PageHeader from '@/components/PageHeader';

type Sku = {
  id: string; asin: string; sku: string | null; title: string;
  current_price: number; cogs: number; contribution_profit: number;
  sales_last_30d: number; inventory_qty: number; reorder_point: number;
  stockout_risk_score: number; margin_delta: number;
};
type Rec = {
  id: string; asin: string; type: string; title: string | null; status: string;
  risk_score: number; expected_impact: number | null; required_approval_level: string;
};
type Exc = { id: string; code: string; message: string; asin: string | null; resolved: boolean };

type SortKey = 'profit30d' | 'risk' | 'cover' | 'title';

export default function Dashboard() {
  const [skus, setSkus] = React.useState<Sku[]>([]);
  const [recs, setRecs] = React.useState<Rec[]>([]);
  const [excs, setExcs] = React.useState<Exc[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [q, setQ] = React.useState('');
  const [sort, setSort] = React.useState<SortKey>('risk');
  const [onlyRisk, setOnlyRisk] = React.useState(false);

  React.useEffect(() => {
    (async () => {
      const [s, r, e] = await Promise.all([
        supabase.from('amazon_skus').select('*'),
        supabase.from('recommendations').select('id,asin,type,title,status,risk_score,expected_impact,required_approval_level'),
        supabase.from('exceptions').select('id,code,message,asin,resolved').eq('resolved', false),
      ]);
      const err = s.error ?? r.error ?? e.error;
      if (err) setError(err.message);
      else {
        setSkus((s.data ?? []) as Sku[]);
        setRecs((r.data ?? []) as Rec[]);
        setExcs((e.data ?? []) as Exc[]);
      }
      setLoading(false);
    })();
  }, []);

  // ---- KPI ----
  const profit30d = skus.reduce((a, s) => a + Number(s.contribution_profit) * s.sales_last_30d, 0);
  const revenue30d = skus.reduce((a, s) => a + Number(s.current_price) * s.sales_last_30d, 0);
  const units30d = skus.reduce((a, s) => a + s.sales_last_30d, 0);
  const atRisk = skus.filter((s) => Number(s.stockout_risk_score) >= 60);
  const belowReorder = skus.filter((s) => s.inventory_qty < s.reorder_point);
  const pending = recs.filter((r) => r.status === 'pending_approval');
  const pendingImpact = pending.reduce((a, r) => a + Number(r.expected_impact ?? 0), 0);
  const openRecsByAsin = recs.reduce<Record<string, number>>((m, r) => {
    if (r.status === 'draft' || r.status === 'pending_approval') m[r.asin] = (m[r.asin] ?? 0) + 1;
    return m;
  }, {});

  const daysOfCover = (s: Sku) => (s.sales_last_30d > 0 ? s.inventory_qty / (s.sales_last_30d / 30) : null);

  // ---- table ----
  const rows = skus
    .filter((s) => !onlyRisk || Number(s.stockout_risk_score) >= 60)
    .filter((s) => {
      const t = q.trim().toLowerCase();
      return !t || s.asin.toLowerCase().includes(t) || s.title.toLowerCase().includes(t) || (s.sku ?? '').toLowerCase().includes(t);
    })
    .sort((a, b) => {
      switch (sort) {
        case 'profit30d': return Number(b.contribution_profit) * b.sales_last_30d - Number(a.contribution_profit) * a.sales_last_30d;
        case 'risk': return Number(b.stockout_risk_score) - Number(a.stockout_risk_score);
        case 'cover': return (daysOfCover(a) ?? 1e9) - (daysOfCover(b) ?? 1e9);
        case 'title': return a.title.localeCompare(b.title, 'vi');
      }
    });

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  return (
    <>
      <PageHeader
        title="Tổng quan vận hành"
        description="Theo dõi lợi nhuận, tồn kho và các việc cần xử lý cho danh mục Amazon của Vexim. Số liệu 30 ngày gần nhất, marketplace US."
        actions={
          <>
            <Link href="/recommendations" className={btn.secondary}>Xem gợi ý</Link>
            <Link href="/add-sku" className={btn.primary}>+ Thêm SKU</Link>
          </>
        }
      />

      {/* KPI */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        <StatCard label="Lợi nhuận góp phần 30 ngày" value={usd(profit30d, 0)} tone="green"
          hint={`Doanh thu ${usd(revenue30d, 0)} · ${num(units30d)} đơn vị`} />
        <StatCard label="Biên lợi nhuận góp phần" value={revenue30d ? `${((profit30d / revenue30d) * 100).toFixed(1)}%` : '—'}
          hint={`Trên ${skus.length} ASIN đang theo dõi`} />
        <StatCard label="ASIN rủi ro hết hàng" value={atRisk.length} tone={atRisk.length ? 'red' : 'default'}
          hint={`${belowReorder.length} ASIN dưới điểm đặt hàng lại`} />
        <StatCard label="Gợi ý chờ duyệt" value={pending.length} tone={pending.length ? 'amber' : 'default'}
          hint={pending.length ? `Tác động ước tính ${usd(pendingImpact, 0)}/tháng` : 'Không có việc tồn đọng'} />
      </div>

      {/* Action queue + exceptions */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-6">
        <Card className="lg:col-span-2">
          <CardHeader title="Cần xử lý hôm nay" subtitle="Gợi ý đang chờ phê duyệt, sắp xếp theo tác động"
            action={<Link href="/recommendations" className={btn.ghost}>Tất cả →</Link>} />
          {pending.length === 0 ? (
            <EmptyState title="Không có gợi ý chờ duyệt" description="Khi pipeline sinh gợi ý mới, chúng sẽ xuất hiện ở đây." />
          ) : (
            <ul className="divide-y divide-gray-100">
              {[...pending].sort((a, b) => Number(b.expected_impact ?? 0) - Number(a.expected_impact ?? 0)).slice(0, 5).map((r) => {
                const sku = skus.find((s) => s.asin === r.asin);
                return (
                  <li key={r.id} className="px-5 py-3 flex items-center gap-4">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium text-gray-900 truncate">{r.title ?? REC_TYPE_LABEL[r.type]}</p>
                      <p className="text-xs text-gray-500 truncate">{r.asin} · {sku?.title ?? ''}</p>
                    </div>
                    <Badge className="bg-gray-50 text-gray-700 ring-gray-500/20 hidden sm:inline-flex">{REC_TYPE_LABEL[r.type] ?? r.type}</Badge>
                    <Badge className="bg-gray-50 text-gray-700 ring-gray-500/20">{r.required_approval_level}</Badge>
                    <span className="text-sm font-semibold text-emerald-700 w-24 text-right">
                      {r.expected_impact != null ? `+${usd(r.expected_impact, 0)}` : '—'}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </Card>

        <Card>
          <CardHeader title="Ngoại lệ đang mở" subtitle={`${excs.length} cảnh báo chưa xử lý`}
            action={<Link href="/exceptions" className={btn.ghost}>Xem →</Link>} />
          {excs.length === 0 ? (
            <EmptyState title="Không có ngoại lệ" />
          ) : (
            <ul className="divide-y divide-gray-100">
              {excs.slice(0, 5).map((e) => (
                <li key={e.id} className="px-5 py-3 flex gap-3">
                  <Badge className={e.code === 'P0' || e.code === 'P1' ? 'bg-red-50 text-red-700 ring-red-600/20' : 'bg-yellow-50 text-yellow-800 ring-yellow-600/20'}>{e.code}</Badge>
                  <div className="min-w-0">
                    <p className="text-sm text-gray-900">{e.message}</p>
                    {e.asin && <p className="text-xs text-gray-500">{e.asin}</p>}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>

      {/* SKU table */}
      <Card>
        <CardHeader title="Danh mục ASIN" subtitle="Hiệu quả và sức khỏe tồn kho của từng sản phẩm"
          action={
            <div className="flex flex-wrap items-center gap-2">
              <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Tìm ASIN, SKU, tên…" className={`${input} w-48`} />
              <select value={sort} onChange={(e) => setSort(e.target.value as SortKey)} className={`${input} w-44`}>
                <option value="risk">Rủi ro cao nhất</option>
                <option value="profit30d">Lợi nhuận 30 ngày</option>
                <option value="cover">Ít ngày hàng nhất</option>
                <option value="title">Tên A→Z</option>
              </select>
              <label className="inline-flex items-center gap-2 text-sm text-gray-700">
                <input type="checkbox" checked={onlyRisk} onChange={(e) => setOnlyRisk(e.target.checked)} className="rounded" />
                Chỉ rủi ro
              </label>
            </div>
          } />
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
              <tr>
                <th className="px-5 py-3 text-left font-medium">Sản phẩm</th>
                <th className="px-4 py-3 text-right font-medium">Giá</th>
                <th className="px-4 py-3 text-right font-medium">LN góp phần / đv</th>
                <th className="px-4 py-3 text-right font-medium">Bán 30 ngày</th>
                <th className="px-4 py-3 text-right font-medium">LN 30 ngày</th>
                <th className="px-4 py-3 text-right font-medium">Tồn kho</th>
                <th className="px-4 py-3 text-right font-medium">Ngày hàng</th>
                <th className="px-4 py-3 text-left font-medium">Rủi ro hết hàng</th>
                <th className="px-4 py-3 text-right font-medium">Gợi ý</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {rows.map((s) => {
                const cp = Number(s.contribution_profit);
                const margin = s.current_price ? (cp / Number(s.current_price)) * 100 : 0;
                const risk = Number(s.stockout_risk_score);
                const lvl = riskLevel(risk);
                const cover = daysOfCover(s);
                const open = openRecsByAsin[s.asin] ?? 0;
                return (
                  <tr key={s.id} className="hover:bg-gray-50/70">
                    <td className="px-5 py-3">
                      <p className="font-medium text-gray-900 max-w-xs truncate">{s.title}</p>
                      <p className="text-xs text-gray-500 font-mono">{s.asin}{s.sku ? ` · ${s.sku}` : ''}</p>
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums">{usd(s.current_price)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">
                      <span className={cp < 0 ? 'text-red-600 font-medium' : 'text-gray-900'}>{usd(cp)}</span>
                      <span className="block text-xs text-gray-500">{margin.toFixed(0)}%</span>
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums">{num(s.sales_last_30d)}</td>
                    <td className="px-4 py-3 text-right tabular-nums font-medium text-gray-900">{usd(cp * s.sales_last_30d, 0)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">
                      <span className={s.inventory_qty < s.reorder_point ? 'text-red-600 font-medium' : ''}>{num(s.inventory_qty)}</span>
                      <span className="block text-xs text-gray-500">ROP {num(s.reorder_point)}</span>
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums">
                      {cover == null ? '—' : <span className={cover < 21 ? 'text-red-600 font-medium' : ''}>{cover.toFixed(0)} ngày</span>}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <div className="w-20 h-1.5 rounded-full bg-gray-200 overflow-hidden">
                          <div className={`h-full ${RISK_META[lvl].dot}`} style={{ width: `${Math.min(100, risk)}%` }} />
                        </div>
                        <Badge className={RISK_META[lvl].cls}>{risk.toFixed(0)} · {RISK_META[lvl].label}</Badge>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-right">
                      {open > 0 ? (
                        <Link href={`/recommendations?asin=${s.asin}`} className={btn.ghost}>{open} đang mở →</Link>
                      ) : (
                        <span className="text-xs text-gray-400">—</span>
                      )}
                    </td>
                  </tr>
                );
              })}
              {rows.length === 0 && (
                <tr>
                  <td colSpan={9}>
                    <EmptyState title={skus.length ? 'Không có ASIN khớp bộ lọc' : 'Chưa có ASIN nào'}
                      action={!skus.length && <Link href="/add-sku" className={btn.primary}>Thêm SKU đầu tiên</Link>} />
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <div className="px-5 py-3 border-t border-gray-100 text-xs text-gray-500">
          LN góp phần = giá − COGS − phí FBA − phí referral. Ngày hàng = tồn kho ÷ tốc độ bán/ngày. ROP = điểm đặt hàng lại.
        </div>
      </Card>
    </>
  );
}
