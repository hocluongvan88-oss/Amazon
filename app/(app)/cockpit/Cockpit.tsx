'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { usd, num, pct } from '@/lib/format';
import { Card, CardHeader, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

// ---------- kiểu dữ liệu (khớp supabase/024_ops_cockpit.sql) ----------
type Badge_ = { feed: string; label: string | null; status: 'fresh' | 'stale' | 'missing'; last_data_date: string | null; last_run_at: string | null; last_run_status: string | null; sla_hours: number | null };
type Group = { badge: Badge_; has_data: boolean; kpi: Record<string, number | null>; items: Record<string, unknown>[] };
type CockpitData = {
  asof: string; generated_at: string; thresholds: Record<string, number>;
  orders: Group; inventory: Group; returns: Group; keywords: Group; traffic: Group; conversion: Group; promotions: Group; reviews: Group; advertising: Group;
};
type Action = {
  key: string; group: string; priority: 'P0' | 'P1' | 'P2' | 'P3'; title: string; owner_role: string; task_type: string;
  evidence: Record<string, unknown>; suggestion: string; link: string; asin?: string; deadline: string; task_id: string | null;
};

const GROUP_META: { key: keyof Omit<CockpitData, 'asof' | 'generated_at' | 'thresholds'>; label: string; icon: string }[] = [
  { key: 'orders', label: 'Đơn hàng', icon: '▤' },
  { key: 'inventory', label: 'Tồn kho', icon: '▦' },
  { key: 'returns', label: 'Trả hàng', icon: '↩' },
  { key: 'keywords', label: 'Từ khoá chuyển đổi', icon: '🔍' },
  { key: 'traffic', label: 'Lưu lượng', icon: '⇢' },
  { key: 'conversion', label: 'Chuyển đổi', icon: '◎' },
  { key: 'promotions', label: 'Khuyến mãi', icon: '%' },
  { key: 'reviews', label: 'Đánh giá', icon: '★' },
  { key: 'advertising', label: 'Quảng cáo', icon: '⚡' },
];
const GROUP_LABEL: Record<string, string> = Object.fromEntries(GROUP_META.map((g) => [g.key, g.label]));
GROUP_LABEL.data_quality = 'Chất lượng dữ liệu';

const ROLE_VI: Record<string, string> = { owner: 'Chủ tài khoản', ops_lead: 'Trưởng vận hành', operator: 'Vận hành', finance: 'Tài chính', content_qa: 'Content/QA', brand_approver: 'Phê duyệt thương hiệu', viewer: 'Xem' };
const PRIO_CLS: Record<string, string> = {
  P0: 'bg-red-50 text-red-700 ring-red-200', P1: 'bg-orange-50 text-orange-700 ring-orange-200',
  P2: 'bg-amber-50 text-amber-700 ring-amber-200', P3: 'bg-gray-50 text-gray-600 ring-gray-200',
};
const DIAG_VI: Record<string, string> = { no_traffic: 'Không có traffic', buy_box: 'Mất Buy Box', reviews: 'Rating thấp', promo_effect: 'Đang KM', content_or_price: 'Nội dung/giá', ok: 'Bình thường' };
const FLAG_VI: Record<string, string> = { spend_while_oos: 'Chi khi hết hàng', spend_no_sales: 'Chi không có đơn', acos_high: 'ACOS cao', ok: 'OK' };
const KIND_VI: Record<string, string> = { harvest: 'Nên thêm exact', negative: 'Nên phủ định', converting: 'Chuyển đổi', watch: 'Theo dõi' };
const HEALTH_VI: Record<string, string> = { critical: 'Nguy cấp', warning: 'Cảnh báo', healthy: 'Ổn', overstock: 'Tồn nhiều', unknown: 'Không rõ' };

// ---------- helpers ----------
function FreshBadge({ b }: { b: Badge_ }) {
  const cls = b.status === 'fresh' ? 'bg-emerald-50 text-emerald-700 ring-emerald-200' : b.status === 'stale' ? 'bg-amber-50 text-amber-700 ring-amber-200' : 'bg-gray-100 text-gray-600 ring-gray-200';
  const label = b.status === 'fresh' ? 'Tươi' : b.status === 'stale' ? 'Quá hạn' : 'Thiếu dữ liệu';
  const title = `Feed: ${b.label ?? b.feed}\nDữ liệu tới: ${b.last_data_date ?? '—'}\nLần nạp gần nhất: ${b.last_run_at ? new Date(b.last_run_at).toLocaleString('vi-VN') : 'chưa có bản ghi'} (${b.last_run_status ?? '—'})\nSLA: ${b.sla_hours ?? '—'}h`;
  return <Badge className={cls}><span title={title}>{label}{b.last_data_date ? ` · ${b.last_data_date}` : ''}</span></Badge>;
}
function Delta({ v }: { v: number | null | undefined }) {
  if (v == null) return <span className="text-gray-400">—</span>;
  const cls = v > 5 ? 'text-emerald-600' : v < -5 ? 'text-red-600' : 'text-gray-500';
  return <span className={cls}>{v > 0 ? '+' : ''}{v.toFixed(1)}%</span>;
}
function Kpi({ label, value, sub }: { label: string; value: React.ReactNode; sub?: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-gray-100 bg-gray-50/60 px-3 py-2">
      <p className="text-[11px] uppercase tracking-wide text-gray-500">{label}</p>
      <p className="text-lg font-semibold text-gray-900">{value}</p>
      {sub && <p className="text-xs text-gray-500">{sub}</p>}
    </div>
  );
}
const s = (o: Record<string, unknown>, k: string) => (o[k] == null ? null : String(o[k]));
const n = (o: Record<string, unknown>, k: string) => (o[k] == null ? null : Number(o[k]));

// ---------- trang ----------
export default function Cockpit() {
  const { tenant, can, loading: tenantLoading } = useTenant();
  const [asof, setAsof] = React.useState(() => { const d = new Date(); d.setDate(d.getDate() - 1); return d.toISOString().slice(0, 10); });
  const [data, setData] = React.useState<CockpitData | null>(null);
  const [actions, setActions] = React.useState<Action[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [err, setErr] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState<string | null>(null);
  const [open, setOpen] = React.useState<string>('orders');
  const [filter, setFilter] = React.useState<string>('all');
  const canOpenTask = can('exception.resolve') || can('voc.triage') || can('content.draft');

  const load = React.useCallback(async () => {
    if (!tenant) return;
    setLoading(true); setErr(null);
    const [c, a] = await Promise.all([
      supabase.rpc('ops_cockpit', { t: tenant.id, asof }),
      supabase.rpc('cockpit_actions', { t: tenant.id, asof }),
    ]);
    if (c.error) setErr(c.error.message.includes('ops_cockpit') ? 'Chưa chạy migration 024_ops_cockpit.sql trên Supabase.' : c.error.message);
    else setData(c.data as CockpitData);
    if (!a.error) setActions((a.data as Action[]) ?? []);
    setLoading(false);
  }, [tenant, asof]);

  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- tải dữ liệu từ Supabase khi tenant/asof đổi
    void load();
  }, [load]);

  async function openTask(a: Action) {
    if (!tenant) return;
    setBusy(a.key);
    const { error } = await supabase.rpc('cockpit_open_task', { t: tenant.id, p_action: a });
    setBusy(null);
    if (error) { alert('Không mở được task: ' + error.message); return; }
    await load();
  }

  if (tenantLoading || (loading && !data)) return <Spinner />;
  if (!tenant) return <EmptyState title="Chưa chọn tenant" />;
  if (err) return <ErrorBox message={err} />;
  if (!data) return <EmptyState title="Không có dữ liệu" />;

  const counts = { P0: 0, P1: 0, P2: 0, P3: 0 } as Record<string, number>;
  actions.forEach((a) => { counts[a.priority] = (counts[a.priority] ?? 0) + 1; });
  const visible = actions.filter((a) => filter === 'all' || a.priority === filter || a.group === filter);
  const missingGroups = GROUP_META.filter((g) => data[g.key].badge.status === 'missing').map((g) => g.label);
  const staleGroups = GROUP_META.filter((g) => data[g.key].badge.status === 'stale').map((g) => g.label);

  return (
    <div className="space-y-6">
      {/* thanh điều khiển */}
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <label className="text-gray-600">Ngày chốt (asof)</label>
        <input type="date" className={`${input} !w-auto`} value={asof} max={new Date().toISOString().slice(0, 10)} onChange={(e) => setAsof(e.target.value)} />
        <button className={btn.secondary} onClick={() => void load()} disabled={loading}>{loading ? 'Đang tải…' : 'Tải lại'}</button>
        <span className="text-xs text-gray-500">Baseline = 30 ngày liền trước cửa sổ 30 ngày · Tạo lúc {new Date(data.generated_at).toLocaleString('vi-VN')}</span>
      </div>

      {(missingGroups.length > 0 || staleGroups.length > 0) && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          {missingGroups.length > 0 && <p><b>Thiếu dữ liệu:</b> {missingGroups.join(', ')} — các chỉ số này hiển thị “—”, <u>không phải bằng 0</u>. <Link href="/import" className="underline">Nhập CSV</Link> hoặc <Link href="/settings/data-sources" className="underline">kết nối API</Link>.</p>}
          {staleGroups.length > 0 && <p><b>Quá hạn SLA:</b> {staleGroups.join(', ')} — quyết định dựa trên số liệu này có thể sai lệch.</p>}
        </div>
      )}

      {/* lưới 9 nhóm */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {GROUP_META.map((g) => {
          const grp = data[g.key];
          const acts = actions.filter((a) => a.group === g.key);
          const p0 = acts.filter((a) => a.priority === 'P0').length; const p1 = acts.filter((a) => a.priority === 'P1').length;
          return (
            <button key={g.key} id={g.key} onClick={() => setOpen(g.key)} className={`text-left rounded-xl border bg-white p-4 shadow-sm transition hover:border-indigo-300 ${open === g.key ? 'border-indigo-400 ring-2 ring-indigo-100' : 'border-gray-200'}`}>
              <div className="flex items-center justify-between">
                <p className="font-semibold text-gray-900">{g.icon} {g.label}</p>
                <FreshBadge b={grp.badge} />
              </div>
              <div className="mt-2 text-sm text-gray-700"><Headline k={g.key} kpi={grp.kpi} /></div>
              <div className="mt-2 flex gap-1.5 text-xs">
                {p0 > 0 && <Badge className={PRIO_CLS.P0}>{p0} P0</Badge>}
                {p1 > 0 && <Badge className={PRIO_CLS.P1}>{p1} P1</Badge>}
                {acts.length - p0 - p1 > 0 && <Badge className={PRIO_CLS.P2}>{acts.length - p0 - p1} P2/P3</Badge>}
                {acts.length === 0 && grp.badge.status !== 'missing' && <span className="text-gray-400">Không có cảnh báo</span>}
              </div>
            </button>
          );
        })}
      </div>

      {/* chi tiết nhóm đang mở */}
      <Card className="p-5">
        <CardHeader title={`${GROUP_LABEL[open]} — chi tiết`} subtitle={`Nguồn: ${data[open as GroupKey].badge.label ?? data[open as GroupKey].badge.feed}`} action={<FreshBadge b={data[open as GroupKey].badge} />} />
        <GroupDetail k={open as GroupKey} grp={data[open as GroupKey]} />
      </Card>

      {/* hàng đợi hành động */}
      <Card className="p-5">
        <CardHeader title="Hàng đợi hành động P0–P3" subtitle="Sinh từ luật xác định trên dữ liệu ở trên. Mỗi mục có bằng chứng, người phụ trách, hạn theo SLA chính sách. Bấm “Mở task” để giao việc — không có bước nào tự thực thi lên Amazon."
          action={
            <div className="flex flex-wrap gap-1.5 text-xs">
              {(['all', 'P0', 'P1', 'P2', 'P3'] as const).map((p) => (
                <button key={p} onClick={() => setFilter(p)} className={`rounded-md px-2 py-1 ring-1 ring-inset ${filter === p ? 'bg-indigo-600 text-white ring-indigo-600' : 'bg-white text-gray-700 ring-gray-200'}`}>{p === 'all' ? `Tất cả (${actions.length})` : `${p} (${counts[p]})`}</button>
              ))}
            </div>
          } />
        {visible.length === 0 ? (
          <EmptyState title="Không có hành động nào" description={actions.length === 0 ? 'Không luật nào kích hoạt với dữ liệu hiện có. Nếu nhiều nhóm “Thiếu dữ liệu”, đây không phải tín hiệu tốt — hãy nạp dữ liệu.' : 'Không có mục nào khớp bộ lọc.'} />
        ) : (
          <ul className="divide-y divide-gray-100">
            {visible.map((a) => (
              <li key={a.key} className="py-3">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge className={PRIO_CLS[a.priority]}>{a.priority}</Badge>
                      <span className="text-xs text-gray-500">{GROUP_LABEL[a.group] ?? a.group}</span>
                      <p className="font-medium text-gray-900">{a.title}</p>
                    </div>
                    <p className="mt-1 text-sm text-gray-600">💡 {a.suggestion}</p>
                    <p className="mt-1 text-xs text-gray-500">
                      Phụ trách: <b>{ROLE_VI[a.owner_role] ?? a.owner_role}</b> · Hạn: {new Date(a.deadline).toLocaleString('vi-VN')}
                      {' · '}<Link href={a.link} className="text-indigo-600 hover:underline">Mở liên kết ↗</Link>
                      {a.task_id && <> · <Link href="/tasks" className="text-emerald-700 hover:underline">Đã có task</Link></>}
                    </p>
                    <details className="mt-1 text-xs">
                      <summary className="cursor-pointer text-gray-500">Bằng chứng</summary>
                      <pre className="mt-1 max-h-40 overflow-auto rounded bg-gray-50 p-2 text-[11px] text-gray-700">{JSON.stringify(a.evidence, null, 1)}</pre>
                    </details>
                  </div>
                  <div className="shrink-0">
                    {a.task_id ? <span className="text-xs text-emerald-700">✓ Task đã mở</span>
                      : canOpenTask ? <button className={btn.primary} disabled={busy === a.key} onClick={() => void openTask(a)}>{busy === a.key ? 'Đang mở…' : 'Mở task'}</button>
                      : <span className="text-xs text-gray-400">Không có quyền mở task</span>}
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

type GroupKey = (typeof GROUP_META)[number]['key'];

function Headline({ k, kpi }: { k: GroupKey; kpi: Record<string, number | null> }) {
  switch (k) {
    case 'orders': return <>7 ngày: <b>{num(kpi.units_7d)}</b> đv · {usd(kpi.revenue_7d, 0)} · so baseline <Delta v={kpi.change_7d_vs_baseline_pct} /></>;
    case 'inventory': return <>{num(kpi.skus)} SKU · <b className="text-red-600">{num(kpi.critical)}</b> nguy cấp · {num(kpi.warning)} cảnh báo · {num(kpi.unknown)} không rõ</>;
    case 'returns': return <>30 ngày: <b>{num(kpi.qty_30d)}</b> đv · tỷ lệ {pct(kpi.rate_30d_pct, 2)} (baseline {pct(kpi.rate_baseline_pct, 2)})</>;
    case 'keywords': return <><b>{num(kpi.converting)}</b>/{num(kpi.terms_30d)} từ khoá chuyển đổi · lãng phí {usd(kpi.wasted_spend_30d, 0)}</>;
    case 'traffic': return <>7 ngày: <b>{num(kpi.sessions_7d)}</b> sessions · CTR {pct(kpi.ctr_7d_pct, 2)} · <Delta v={kpi.change_7d_vs_baseline_pct} /></>;
    case 'conversion': return <>CVR 7 ngày <b>{pct(kpi.cvr_7d_pct, 2)}</b> · baseline {pct(kpi.cvr_baseline_pct, 2)} · <Delta v={kpi.change_7d_vs_baseline_pct} /></>;
    case 'promotions': return <><b>{num(kpi.active)}</b> đang chạy · {num(kpi.upcoming)} sắp · {num(kpi.negative_margin)} biên âm</>;
    case 'reviews': return <>30 ngày: <b>{num(kpi.count_30d)}</b> review · TB {kpi.avg_rating_30d ?? '—'}★ · {num(kpi.low_7d)} thấp/7 ngày</>;
    case 'advertising': return <>7 ngày: chi <b>{usd(kpi.spend_7d, 0)}</b> · ACOS {pct(kpi.acos_7d_pct)} · TACOS {pct(kpi.tacos_7d_pct)}</>;
  }
}

function Table({ cols, rows, render }: { cols: string[]; rows: Record<string, unknown>[]; render: (r: Record<string, unknown>) => React.ReactNode[] }) {
  if (rows.length === 0) return <p className="mt-3 text-sm text-gray-500">Không có dòng nào trong cửa sổ này.</p>;
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="min-w-full text-sm">
        <thead><tr className="text-left text-xs uppercase tracking-wide text-gray-500">{cols.map((c) => <th key={c} className="px-2 py-1.5 font-medium">{c}</th>)}</tr></thead>
        <tbody className="divide-y divide-gray-100">
          {rows.slice(0, 40).map((r, i) => <tr key={i}>{render(r).map((c, j) => <td key={j} className="px-2 py-1.5 align-top">{c}</td>)}</tr>)}
        </tbody>
      </table>
      {rows.length > 40 && <p className="mt-1 text-xs text-gray-500">Hiển thị 40/{rows.length} dòng.</p>}
    </div>
  );
}

function GroupDetail({ k, grp }: { k: GroupKey; grp: Group }) {
  const kpi = grp.kpi; const items = grp.items;
  if (grp.badge.status === 'missing' && !grp.has_data) {
    return <EmptyState title="Chưa có dữ liệu cho nhóm này" description="Các chỉ số không được tính — không được hiểu là 0. Nhập CSV theo mẫu hoặc bật connector tương ứng." action={<Link href="/import" className={btn.secondary}>Nhập dữ liệu</Link>} />;
  }
  const asinCell = (r: Record<string, unknown>) => <span><span className="font-mono text-xs">{s(r, 'asin')}</span><br /><span className="text-xs text-gray-500">{(s(r, 'title') ?? '').slice(0, 40)}</span></span>;
  switch (k) {
    case 'orders': return (<>
      <div className="grid gap-2 sm:grid-cols-4">
        <Kpi label="Hôm qua" value={num(kpi.units_1d)} sub={usd(kpi.revenue_1d, 0)} />
        <Kpi label="7 ngày" value={num(kpi.units_7d)} sub={`${usd(kpi.revenue_7d, 0)} · ${num(kpi.units_7d_daily, 1)}/ngày · phủ ${kpi.coverage_7d ?? '—'}/7 ngày`} />
        <Kpi label="30 ngày" value={num(kpi.units_30d)} sub={`${usd(kpi.revenue_30d, 0)} · ${num(kpi.units_30d_daily, 1)}/ngày`} />
        <Kpi label="Baseline (30 ngày trước)" value={num(kpi.units_baseline_daily, 1) + '/ngày'} sub={<>7 ngày vs baseline: <Delta v={kpi.change_7d_vs_baseline_pct} /></>} />
      </div>
      <Table cols={['ASIN', 'Đv 7 ngày', 'Đv 30 ngày', 'Baseline 30', 'Δ (quy 30 ngày)', 'Bán gần nhất']} rows={items} render={(r) => [asinCell(r), num(n(r, 'units_7d')), num(n(r, 'units_30d')), num(n(r, 'units_baseline')), <Delta key="d" v={n(r, 'change_pct')} />, s(r, 'last_sale') ?? '—']} />
    </>);
    case 'inventory': return (<>
      <div className="grid gap-2 sm:grid-cols-5">
        <Kpi label="Nguy cấp" value={<span className="text-red-600">{num(kpi.critical)}</span>} /><Kpi label="Cảnh báo" value={num(kpi.warning)} /><Kpi label="Tồn nhiều" value={num(kpi.overstock)} />
        <Kpi label="Khả dụng / inbound" value={num(kpi.units_available)} sub={`inbound ${num(kpi.units_inbound)}`} /><Kpi label="Unfulfillable / aged 180+" value={num(kpi.unfulfillable)} sub={`aged ${num(kpi.aged_180_plus)}`} />
      </div>
      <Table cols={['ASIN', 'Sức khoẻ', 'Khả dụng', 'Inbound', 'Tốc độ 7/30', 'Ngày còn', 'Dự kiến hết', 'Unfulfillable']} rows={items} render={(r) => [asinCell(r),
        <Badge key="h" className={s(r, 'inventory_health') === 'critical' ? PRIO_CLS.P0 : s(r, 'inventory_health') === 'warning' ? PRIO_CLS.P1 : PRIO_CLS.P3}>{HEALTH_VI[s(r, 'inventory_health') ?? 'unknown']}</Badge>,
        num(n(r, 'available')), num(n(r, 'inbound')), `${num(n(r, 'velocity_7d'), 1)} / ${num(n(r, 'velocity_30d'), 1)}`, num(n(r, 'days_of_cover'), 1), s(r, 'stockout_eta') ?? '—', num(n(r, 'unfulfillable'))]} />
    </>);
    case 'returns': return (<>
      <div className="grid gap-2 sm:grid-cols-4">
        <Kpi label="7 ngày" value={num(kpi.qty_7d)} /><Kpi label="30 ngày" value={num(kpi.qty_30d)} sub={`hoàn ${usd(kpi.refund_30d, 0)}`} />
        <Kpi label="Tỷ lệ 30 ngày" value={pct(kpi.rate_30d_pct, 2)} sub="trên đơn vị bán cùng kỳ" /><Kpi label="Baseline" value={pct(kpi.rate_baseline_pct, 2)} sub={`${num(kpi.qty_baseline_30d)} đv`} />
      </div>
      <Table cols={['ASIN', 'Trả 30 ngày', 'Bán 30 ngày', 'Tỷ lệ', 'Lý do chính', 'Bình luận khách']} rows={items} render={(r) => [asinCell(r), num(n(r, 'q30')), num(n(r, 'u30')), pct(n(r, 'rate_pct')),
        <span key="r" className="text-xs">{((r.top_reasons as string[] | null) ?? []).join(', ') || '—'}</span>, <span key="c" className="text-xs text-gray-600">{((r.comments as string[] | null) ?? []).join(' · ') || '—'}</span>]} />
    </>);
    case 'keywords': return (<>
      <div className="grid gap-2 sm:grid-cols-4">
        <Kpi label="Từ khoá 30 ngày" value={num(kpi.terms_30d)} /><Kpi label="Chuyển đổi" value={num(kpi.converting)} /><Kpi label="Chi / doanh thu QC" value={usd(kpi.spend_30d, 0)} sub={usd(kpi.sales_30d, 0)} /><Kpi label="Lãng phí (≥ ngưỡng click, 0 đơn)" value={usd(kpi.wasted_spend_30d, 0)} />
      </div>
      <Table cols={['Từ khoá tìm kiếm', 'Nhãn', 'Hiển thị', 'Click', 'Chi', 'Đơn', 'CVR', 'ACOS', 'Campaign']} rows={items} render={(r) => [<span key="t" className="font-medium">{s(r, 'search_term')}</span>,
        <Badge key="k" className={s(r, 'kind') === 'harvest' ? 'bg-emerald-50 text-emerald-700 ring-emerald-200' : s(r, 'kind') === 'negative' ? PRIO_CLS.P1 : PRIO_CLS.P3}>{KIND_VI[s(r, 'kind') ?? 'watch']}</Badge>,
        num(n(r, 'impressions')), num(n(r, 'clicks')), usd(n(r, 'spend')), num(n(r, 'orders')), pct(n(r, 'cvr_pct')), pct(n(r, 'acos_pct')), <span key="c" className="text-xs">{((r.campaigns as string[] | null) ?? []).join(', ')}</span>]} />
    </>);
    case 'traffic': return (<>
      <div className="grid gap-2 sm:grid-cols-5">
        <Kpi label="Hôm qua" value={num(kpi.sessions_1d)} /><Kpi label="7 ngày" value={num(kpi.sessions_7d)} sub={`${num(kpi.sessions_7d_daily, 1)}/ngày · phủ ${kpi.coverage_7d ?? '—'}/7`} /><Kpi label="Baseline" value={num(kpi.sessions_baseline_daily, 1) + '/ngày'} sub={<Delta v={kpi.change_7d_vs_baseline_pct} />} />
        <Kpi label="Hiển thị / CTR 7 ngày" value={num(kpi.impressions_7d)} sub={pct(kpi.ctr_7d_pct, 2)} /><Kpi label="Tỷ trọng paid (ước)" value={pct(kpi.paid_share_7d_pct)} sub="click QC / sessions" />
      </div>
      <Table cols={['ASIN', 'Sessions 7 ngày', 'Baseline 30', 'Δ', 'Buy Box', 'Click QC 7 ngày', 'Paid %']} rows={items} render={(r) => [asinCell(r), num(n(r, 'sessions_7d')), num(n(r, 'sessions_baseline')), <Delta key="d" v={n(r, 'change_pct')} />, pct(n(r, 'buy_box_pct')), num(n(r, 'paid_clicks_7d')), pct(n(r, 'paid_share_pct'))]} />
    </>);
    case 'conversion': return (<>
      <div className="grid gap-2 sm:grid-cols-4">
        <Kpi label="CVR 7 ngày" value={pct(kpi.cvr_7d_pct, 2)} /><Kpi label="CVR 30 ngày" value={pct(kpi.cvr_30d_pct, 2)} /><Kpi label="Baseline" value={pct(kpi.cvr_baseline_pct, 2)} /><Kpi label="Δ 7 ngày vs baseline" value={<Delta v={kpi.change_7d_vs_baseline_pct} />} />
      </div>
      <Table cols={['ASIN', 'Chẩn đoán', 'CVR 7 ngày', 'Baseline', 'Δ', 'Sessions', 'Buy Box', 'Rating 30 ngày', 'KM', 'Giá']} rows={items} render={(r) => [asinCell(r),
        <Badge key="d" className={s(r, 'diagnosis') === 'ok' ? PRIO_CLS.P3 : PRIO_CLS.P1}>{DIAG_VI[s(r, 'diagnosis') ?? 'ok']}</Badge>,
        pct(n(r, 'cvr_7d_pct'), 2), pct(n(r, 'cvr_baseline_pct'), 2), <Delta key="x" v={n(r, 'change_pct')} />, num(n(r, 'sessions_7d')), pct(n(r, 'buy_box_pct')), n(r, 'rating_30d') ?? '—', num(n(r, 'promos_active')), usd(n(r, 'price'))]} />
    </>);
    case 'promotions': return (<>
      <div className="grid gap-2 sm:grid-cols-4">
        <Kpi label="Đang chạy" value={num(kpi.active)} /><Kpi label="Sắp chạy (14 ngày)" value={num(kpi.upcoming)} /><Kpi label="Kết thúc 30 ngày" value={num(kpi.ended_30d)} /><Kpi label="Biên âm" value={<span className={kpi.negative_margin ? 'text-red-600' : ''}>{num(kpi.negative_margin)}</span>} />
      </div>
      <Table cols={['KM', 'Loại', 'Giai đoạn', 'ASIN', 'Thời gian', 'Giảm', 'Biên sau KM (thấp nhất)', 'Đv/ngày trong KM', 'Trước KM', 'Lift']} rows={items} render={(r) => [<span key="n"><b>{s(r, 'promo_id')}</b><br /><span className="text-xs text-gray-500">{s(r, 'name')}</span></span>, s(r, 'type'),
        <Badge key="p" className={s(r, 'phase') === 'active' ? 'bg-emerald-50 text-emerald-700 ring-emerald-200' : PRIO_CLS.P3}>{s(r, 'phase') === 'active' ? 'Đang chạy' : s(r, 'phase') === 'upcoming' ? 'Sắp chạy' : 'Đã kết thúc'}</Badge>,
        <span key="a" className="font-mono text-xs">{((r.asins as string[]) ?? []).join(', ')}</span>, `${s(r, 'start_at')} → ${s(r, 'end_at') ?? '…'}`, `${n(r, 'discount_value') ?? '—'}${s(r, 'discount_type') === 'percent' ? '%' : ''}`,
        <span key="m" className={(n(r, 'min_margin_after_pct') ?? 0) < 0 ? 'text-red-600 font-medium' : ''}>{pct(n(r, 'min_margin_after_pct'))}</span>, num(n(r, 'units_in_daily'), 1), num(n(r, 'units_pre_daily'), 1), <Delta key="l" v={n(r, 'lift_pct')} />]} />
    </>);
    case 'reviews': return (<>
      <div className="grid gap-2 sm:grid-cols-4">
        <Kpi label="7 ngày" value={num(kpi.count_7d)} sub={`${num(kpi.low_7d)} review thấp`} /><Kpi label="30 ngày" value={num(kpi.count_30d)} /><Kpi label="Rating TB 30 ngày" value={kpi.avg_rating_30d ?? '—'} /><Kpi label="Baseline" value={kpi.avg_rating_baseline ?? '—'} />
      </div>
      <p className="mt-3 text-xs text-gray-500">Review thấp 30 ngày (≤ ngưỡng). Không phản hồi để xin đổi sao — chỉ dùng làm tín hiệu chất lượng/nội dung.</p>
      <Table cols={['Ngày', 'ASIN', '★', 'Nội dung', 'Chủ đề', 'Trả hàng cùng kỳ']} rows={items} render={(r) => [s(r, 'd'), <span key="a" className="font-mono text-xs">{s(r, 'asin')}</span>, n(r, 'rating'), <span key="b" className="text-xs"><b>{s(r, 'title')}</b> {s(r, 'body')}</span>,
        <span key="t" className="text-xs">{((r.topics as string[] | null) ?? []).join(', ') || '—'}</span>, r.has_nearby_return ? <Badge key="r" className={PRIO_CLS.P1}>Có</Badge> : 'Không']} />
    </>);
    case 'advertising': return (<>
      <div className="grid gap-2 sm:grid-cols-5">
        <Kpi label="Chi 7 ngày" value={usd(kpi.spend_7d, 0)} sub={`DT QC ${usd(kpi.sales_7d, 0)}`} /><Kpi label="ACOS 7 ngày" value={pct(kpi.acos_7d_pct)} sub={`30 ngày ${pct(kpi.acos_30d_pct)}`} /><Kpi label="ACOS baseline" value={pct(kpi.acos_baseline_pct)} /><Kpi label="TACOS 7 ngày" value={pct(kpi.tacos_7d_pct)} sub="chi QC / doanh thu đơn" /><Kpi label="Click / CTR" value={num(kpi.clicks_7d)} sub={pct(kpi.ctr_7d_pct, 2)} />
      </div>
      <Table cols={['ASIN', 'Cờ', 'Chi 7 ngày', 'DT QC', 'ACOS', 'Baseline', 'Click', 'Đơn', 'Tồn']} rows={items} render={(r) => [asinCell(r),
        <Badge key="f" className={s(r, 'flag') === 'spend_while_oos' ? PRIO_CLS.P0 : s(r, 'flag') === 'ok' ? PRIO_CLS.P3 : PRIO_CLS.P1}>{FLAG_VI[s(r, 'flag') ?? 'ok']}</Badge>,
        usd(n(r, 'spend_7d')), usd(n(r, 'sales_7d')), pct(n(r, 'acos_7d_pct')), pct(n(r, 'acos_baseline_pct')), num(n(r, 'clicks_7d')), num(n(r, 'orders_7d')), num(n(r, 'inventory_qty'))]} />
    </>);
  }
}
