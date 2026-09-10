'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Badge, Spinner, ErrorBox, EmptyState, btn, input } from '@/components/ui';

type Freshness = {
  feed_key: string; domain: string; label: string; sla_hours: number; settlement_lag_days: number; required_for_readiness: boolean;
  last_success_at: string | null; last_run_status: string | null; last_rows_ok: number | null; last_rows_failed: number | null;
  last_data_date: string | null; expected_through: string; age_hours: number | null; status: 'fresh' | 'stale' | 'missing'; source_kind: string | null;
};
type Source = { id: string; kind: 'csv_manual' | 'sp_api' | 'ads_api'; name: string; enabled: boolean; feeds: string[]; config: Record<string, unknown>; status: string; last_run_at: string | null; last_error: string | null; credential_ref: string | null };
type Run = { id: string; feed_key: string; status: string; triggered_by: string; rows_ok: number; rows_failed: number; external_ref: string | null; finished_at: string | null; created_at: string; window_start: string | null; window_end: string | null };

const ST: Record<string, { label: string; cls: string }> = {
  fresh: { label: 'Tươi', cls: 'bg-emerald-100 text-emerald-800' },
  stale: { label: 'Quá hạn', cls: 'bg-amber-100 text-amber-800' },
  missing: { label: 'Chưa có', cls: 'bg-gray-100 text-gray-700' },
};
const RUN_ST: Record<string, string> = { succeeded: 'text-emerald-700', partial: 'text-amber-700', failed: 'text-red-700', queued: 'text-gray-500', running: 'text-sky-700', cancelled: 'text-gray-500' };
const KIND: Record<string, string> = { csv_manual: 'CSV thủ công', sp_api: 'Amazon SP‑API', ads_api: 'Amazon Ads API' };
const SRC_ST: Record<string, string> = { connected: 'Đã kết nối', not_connected: 'Chưa kết nối (chờ P2)', error: 'Lỗi', disabled: 'Tắt' };
const DOMAIN: Record<string, string> = { data: 'Danh mục', finance: 'Tài chính', inventory: 'Tồn kho', revenue: 'Doanh thu', ads: 'Quảng cáo', voc: 'VoC' };
const fmt = (s: string | null) => (s ? new Date(s).toLocaleString('vi-VN', { hour12: false }) : '—');
const ago = (h: number | null) => (h == null ? '—' : h < 48 ? `${Math.round(h)} giờ` : `${Math.round(h / 24)} ngày`);

export default function DataSources() {
  const { tenant, can } = useTenant();
  const [fresh, setFresh] = React.useState<Freshness[]>([]);
  const [sources, setSources] = React.useState<Source[]>([]);
  const [runs, setRuns] = React.useState<Run[]>([]);
  const [err, setErr] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [form, setForm] = React.useState<{ kind: 'sp_api' | 'ads_api'; name: string; marketplace: string; cred: string; feeds: string[] } | null>(null);
  const [saving, setSaving] = React.useState(false);
  const canEdit = can('policy.edit');

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const [f, s, r] = await Promise.all([
      supabase.from('v_data_freshness').select('*').eq('tenant_id', tenant.id).order('required_for_readiness', { ascending: false }).order('feed_key').limit(50),
      supabase.from('v_data_sources').select('*').eq('tenant_id', tenant.id).order('kind').limit(50),
      supabase.from('ingestion_runs').select('id,feed_key,status,triggered_by,rows_ok,rows_failed,external_ref,finished_at,created_at,window_start,window_end').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(50),
    ]);
    if (f.error) setErr(f.error.message.includes('v_data_freshness') ? 'Chưa chạy migration 015_connectors_freshness.sql' : f.error.message);
    setFresh((f.data ?? []) as Freshness[]);
    setSources((s.data ?? []) as Source[]);
    setRuns((r.data ?? []) as Run[]);
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch
    void load();
  }, [load]);

  const save = async () => {
    if (!tenant || !form) return;
    setSaving(true);
    const { error } = await supabase.rpc('upsert_data_source', {
      t: tenant.id, p_kind: form.kind, p_name: form.name || KIND[form.kind], p_feeds: form.feeds,
      p_config: form.kind === 'sp_api' ? { marketplace_id: form.marketplace } : { ads_profile_id: form.marketplace },
      p_credential_ref: form.cred || null, p_enabled: true,
    });
    setSaving(false);
    if (error) { alert(error.message); return; }
    setForm(null); void load();
  };

  if (loading) return <Spinner />;
  if (err) return <ErrorBox message={err} />;

  const required = fresh.filter((f) => f.required_for_readiness);
  const reqOk = required.length > 0 && required.every((f) => f.status === 'fresh');

  return (
    <div className="space-y-6">
      <div className={`rounded-lg border px-4 py-3 text-sm ${reqOk ? 'border-emerald-200 bg-emerald-50 text-emerald-900' : 'border-amber-300 bg-amber-50 text-amber-900'}`}>
        {reqOk ? '✓ Tất cả feed bắt buộc đều tươi — gợi ý & đo lường đáng tin cậy.' : `⚠ ${required.filter((f) => f.status !== 'fresh').length}/${required.length} feed bắt buộc chưa tươi. Rule engine vẫn chạy nhưng kết quả bị gắn cờ; hãy nhập dữ liệu hoặc kết nối API.`}
      </div>

      <Card>
        <CardHeader title="Độ tươi theo feed" subtitle="SLA theo hợp đồng connector (docs/CONNECTOR_CONTRACT_v0.1.md). Ads tính trên ngày đã “settle” (trễ 3 ngày theo khuyến nghị Amazon)." />
        <div className="overflow-x-auto px-5 py-3">
          <table className="w-full text-sm">
            <thead className="text-left text-xs uppercase text-gray-500 border-b">
              <tr><th className="py-2 pr-3">Feed</th><th className="pr-3">Nhóm</th><th className="pr-3">Trạng thái</th><th className="pr-3">Lần lấy thành công</th><th className="pr-3">Tuổi</th><th className="pr-3">Dữ liệu tới ngày</th><th className="pr-3">Kỳ vọng tới</th><th className="pr-3">SLA</th><th>Nguồn</th></tr>
            </thead>
            <tbody>
              {fresh.map((f) => (
                <tr key={f.feed_key} className="border-b last:border-0">
                  <td className="py-2 pr-3 font-medium">{f.label}{f.required_for_readiness && <span className="ml-1 text-[10px] text-indigo-600">bắt buộc</span>}<div className="text-[11px] text-gray-400 font-mono">{f.feed_key}</div></td>
                  <td className="pr-3 text-gray-600">{DOMAIN[f.domain] ?? f.domain}</td>
                  <td className="pr-3"><Badge className={ST[f.status].cls}>{ST[f.status].label}</Badge></td>
                  <td className="pr-3 text-gray-600">{fmt(f.last_success_at)}{f.last_run_status && f.last_run_status !== 'succeeded' && <span className={`ml-1 text-xs ${RUN_ST[f.last_run_status]}`}>({f.last_run_status})</span>}</td>
                  <td className="pr-3">{ago(f.age_hours)}</td>
                  <td className="pr-3">{f.last_data_date ?? '—'}</td>
                  <td className="pr-3 text-gray-500">{f.expected_through}{f.settlement_lag_days > 0 && <span className="text-[10px]"> (trễ {f.settlement_lag_days}d)</span>}</td>
                  <td className="pr-3 text-gray-500">{f.sla_hours}h</td>
                  <td className="text-gray-600">{f.source_kind ? KIND[f.source_kind] : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <Card>
        <CardHeader title="Nguồn kết nối" subtitle="Secret không bao giờ lưu ở đây — chỉ tên khoá trong Vault (credential_ref). Connector SP‑API/Ads API thực thi ở P2; đăng ký trước để feed/freshness sẵn sàng."
          action={canEdit && !form ? <button className={btn.secondary} onClick={() => setForm({ kind: 'sp_api', name: '', marketplace: 'ATVPDKIKX0DER', cred: '', feeds: ['orders_daily', 'inventory', 'sales_traffic_daily'] })}>+ Đăng ký nguồn API</button> : undefined} />
        <div className="px-5 py-4">
        {form && (
          <div className="mb-4 rounded-lg border border-indigo-200 bg-indigo-50/40 p-3 grid gap-2 sm:grid-cols-2 text-sm">
            <label>Loại<select className={input} value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value as 'sp_api' | 'ads_api', feeds: e.target.value === 'ads_api' ? ['ads_daily'] : ['orders_daily', 'inventory', 'sales_traffic_daily'] })}><option value="sp_api">Amazon SP‑API</option><option value="ads_api">Amazon Ads API</option></select></label>
            <label>Tên<input className={input} value={form.name} placeholder={KIND[form.kind]} onChange={(e) => setForm({ ...form, name: e.target.value })} /></label>
            <label>{form.kind === 'sp_api' ? 'Marketplace ID' : 'Ads profile ID'}<input className={input} value={form.marketplace} onChange={(e) => setForm({ ...form, marketplace: e.target.value })} /></label>
            <label>credential_ref (tên khoá Vault)<input className={input} value={form.cred} placeholder="vault:spapi_us" onChange={(e) => setForm({ ...form, cred: e.target.value })} /></label>
            <div className="sm:col-span-2 flex flex-wrap gap-3">
              {fresh.map((f) => (
                <label key={f.feed_key} className="flex items-center gap-1 text-xs"><input type="checkbox" checked={form.feeds.includes(f.feed_key)} onChange={(e) => setForm({ ...form, feeds: e.target.checked ? [...form.feeds, f.feed_key] : form.feeds.filter((k) => k !== f.feed_key) })} />{f.label}</label>
              ))}
            </div>
            <div className="sm:col-span-2 flex gap-2"><button className={btn.primary} disabled={saving} onClick={save}>{saving ? 'Đang lưu…' : 'Lưu nguồn'}</button><button className={btn.secondary} onClick={() => setForm(null)}>Huỷ</button></div>
          </div>
        )}
        {sources.length === 0 ? <EmptyState title="Chưa có nguồn" /> : (
          <ul className="divide-y">
            {sources.map((s) => (
              <li key={s.id} className="py-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
                <span className="font-medium">{s.name}</span>
                <Badge className="bg-gray-100 text-gray-700">{KIND[s.kind]}</Badge>
                <Badge className={s.status === 'connected' ? 'bg-emerald-100 text-emerald-800' : s.status === 'error' ? 'bg-red-100 text-red-800' : 'bg-gray-100 text-gray-600'}>{SRC_ST[s.status] ?? s.status}</Badge>
                <span className="text-gray-500 text-xs">feeds: {s.feeds.join(', ')}</span>
                <span className="text-gray-500 text-xs">lần cuối: {fmt(s.last_run_at)}</span>
                {s.credential_ref && <span className="text-gray-400 text-xs font-mono">{s.credential_ref}</span>}
                {s.last_error && <span className="text-red-600 text-xs">{s.last_error}</span>}
              </li>
            ))}
          </ul>
        )}
        </div>
      </Card>

      <Card>
        <CardHeader title="Lần lấy dữ liệu gần đây" subtitle="Mỗi lần nhập CSV hay kéo API đều là một ingestion_run — cùng một sổ ghi cho mọi nguồn." action={<Link href="/import" className={btn.secondary}>Nhập CSV</Link>} />
        <div className="overflow-x-auto px-5 py-3">
        {runs.length === 0 ? <EmptyState title="Chưa có lần lấy dữ liệu nào" description="Nhập CSV ở mục Nhập dữ liệu để bắt đầu." /> : (
          <table className="w-full text-sm">
            <thead className="text-left text-xs uppercase text-gray-500 border-b"><tr><th className="py-2 pr-3">Thời điểm</th><th className="pr-3">Feed</th><th className="pr-3">Trạng thái</th><th className="pr-3">Dòng OK / lỗi</th><th className="pr-3">Cửa sổ</th><th className="pr-3">Kích hoạt</th><th>Tham chiếu</th></tr></thead>
            <tbody>
              {runs.map((r) => (
                <tr key={r.id} className="border-b last:border-0">
                  <td className="py-1.5 pr-3 text-gray-600">{fmt(r.finished_at ?? r.created_at)}</td>
                  <td className="pr-3 font-mono text-xs">{r.feed_key}</td>
                  <td className={`pr-3 ${RUN_ST[r.status] ?? ''}`}>{r.status}</td>
                  <td className="pr-3">{r.rows_ok} / {r.rows_failed}</td>
                  <td className="pr-3 text-gray-500">{r.window_start ? `${r.window_start} → ${r.window_end}` : '—'}</td>
                  <td className="pr-3 text-gray-500">{r.triggered_by}</td>
                  <td className="text-gray-500 text-xs truncate max-w-[200px]">{r.external_ref ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        </div>
      </Card>
    </div>
  );
}
