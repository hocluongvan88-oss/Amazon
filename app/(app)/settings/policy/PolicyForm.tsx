'use client';

import React from 'react';
import { RULE_LABEL } from '@/app/(app)/exceptions/ExceptionsList';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { Card, CardHeader, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Policy = {
  risk_l0_max: number; risk_l1_max: number;
  price_change_l0_pct: number; price_change_l2_pct: number; price_change_max_pct: number; min_margin_pct: number;
  stockout_p0: number; stockout_p1: number; stockout_p2: number; margin_drop_p1_pct: number;
  risk_weights: { margin_delta: number; inventory_health: number; velocity: number; volatility: number };
  default_lead_time_days: number; safety_stock_days: number;
  data_readiness_target_pct: number; revenue_tolerance_pct: number;
  automation_live: boolean | null; canary_asins: string[] | null; rollback_watch_hours: number | null; rollback_units_drop_pct: number | null; max_live_actions_per_day: number | null;
  sla_hours: Record<'P0' | 'P1' | 'P2' | 'P3', number> | null; cooldown_days: number | null; rule_toggles: Record<string, boolean> | null;
  updated_at: string;
};

export default function PolicyForm() {
  const { tenant } = useTenant();
  const isOwner = tenant?.role === 'owner';
  const [p, setP] = React.useState<Policy | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [saving, setSaving] = React.useState(false);
  const [saved, setSaved] = React.useState(false);

  React.useEffect(() => {
    if (!tenant) return;
    (async () => {
      const { data, error: e } = await supabase.from('policy_register').select('*').eq('tenant_id', tenant.id).single();
      if (e) setError(e.message); else setP(data as Policy);
    })();
  }, [tenant]);

  if (error) return <ErrorBox message={error} />;
  if (!p) return <Spinner />;

  const set = (k: keyof Policy) => (e: React.ChangeEvent<HTMLInputElement>) => setP({ ...p, [k]: Number(e.target.value) });
  const setW = (k: keyof Policy['risk_weights']) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setP({ ...p, risk_weights: { ...p.risk_weights, [k]: Number(e.target.value) } });
  const wSum = Object.values(p.risk_weights).reduce((a, b) => a + b, 0);
  const sla = p.sla_hours ?? { P0: 4, P1: 24, P2: 72, P3: 168 };
  const setSla = (k: keyof typeof sla) => (e: React.ChangeEvent<HTMLInputElement>) => setP({ ...p, sla_hours: { ...sla, [k]: Number(e.target.value) } });
  const toggles = p.rule_toggles ?? {};
  const setToggle = (code: string, on: boolean) => { const t = { ...toggles }; if (on) delete t[code]; else t[code] = false; setP({ ...p, rule_toggles: t }); };

  const problems: string[] = [];
  if (p.risk_l0_max > p.risk_l1_max) problems.push('Ngưỡng L0 phải ≤ ngưỡng L1');
  if (!(p.price_change_l0_pct <= p.price_change_l2_pct && p.price_change_l2_pct <= p.price_change_max_pct)) problems.push('Đổi giá: L0 ≤ L2 ≤ tối đa');
  if (!(p.stockout_p2 <= p.stockout_p1 && p.stockout_p1 <= p.stockout_p0)) problems.push('Hết hàng: P2 ≤ P1 ≤ P0');
  if (Math.abs(wSum - 1) > 0.001) problems.push(`Tổng trọng số risk phải = 1 (hiện ${wSum.toFixed(2)})`);

  async function save() {
    if (!tenant || !p) return;
    setSaving(true); setSaved(false); setError(null);
    const { updated_at: _u, ...patch } = p; void _u;
    const { error: e } = await supabase.from('policy_register').update(patch).eq('tenant_id', tenant.id);
    setSaving(false);
    if (e) setError(e.message); else setSaved(true);
  }

  const ro = !isOwner;

  return (
    <div className="space-y-6 max-w-4xl">
      {ro && <p className="text-sm text-gray-600 bg-yellow-50 border border-yellow-200 rounded-lg p-3">Bạn đang xem ở chế độ chỉ đọc. Chỉ Owner mới sửa được chính sách.</p>}

      <Card>
        <CardHeader title="Cấp duyệt theo điểm rủi ro" subtitle="Áp cho gợi ý mới được tạo. Điểm 0–100." />
        <div className="p-5 grid sm:grid-cols-3 gap-4">
          <F label="L0 (tự động) nếu rủi ro ≤" v={p.risk_l0_max} on={set('risk_l0_max')} ro={ro} unit="điểm" />
          <F label="L1 (operator) nếu rủi ro ≤" v={p.risk_l1_max} on={set('risk_l1_max')} ro={ro} unit="điểm" />
          <div className="text-sm text-gray-600 self-end pb-2">Trên {p.risk_l1_max} điểm → <b>L2 (owner)</b></div>
        </div>
        <Ladder items={[['L0', `≤ ${p.risk_l0_max}`], ['L1', `≤ ${p.risk_l1_max}`], ['L2', `> ${p.risk_l1_max}`]]} />
      </Card>

      <Card>
        <CardHeader title="Điều chỉnh giá" subtitle="Giới hạn theo % thay đổi so với giá hiện tại; áp thêm lên cấp duyệt từ rủi ro." />
        <div className="p-5 grid sm:grid-cols-4 gap-4">
          <F label="L0 nếu |Δ| ≤" v={p.price_change_l0_pct} on={set('price_change_l0_pct')} ro={ro} unit="%" step={0.5} />
          <F label="Buộc L2 nếu |Δ| >" v={p.price_change_l2_pct} on={set('price_change_l2_pct')} ro={ro} unit="%" step={0.5} />
          <F label="Chặn nếu |Δ| >" v={p.price_change_max_pct} on={set('price_change_max_pct')} ro={ro} unit="%" step={0.5} />
          <F label="Biên CP tối thiểu" v={p.min_margin_pct} on={set('min_margin_pct')} ro={ro} unit="%" step={0.5} />
        </div>
      </Card>

      <Card>
        <CardHeader title="Ngưỡng ngoại lệ (P‑level)" subtitle="Dùng cho rule engine tự sinh cảnh báo (tuần 5–6)." />
        <div className="p-5 grid sm:grid-cols-4 gap-4">
          <F label="P0 nếu rủi ro hết hàng ≥" v={p.stockout_p0} on={set('stockout_p0')} ro={ro} />
          <F label="P1 nếu ≥" v={p.stockout_p1} on={set('stockout_p1')} ro={ro} />
          <F label="P2 nếu ≥" v={p.stockout_p2} on={set('stockout_p2')} ro={ro} />
          <F label="P1 nếu biên CP giảm >" v={p.margin_drop_p1_pct} on={set('margin_drop_p1_pct')} ro={ro} unit="điểm %" step={0.5} />
        </div>
      </Card>

      <Card>
        <CardHeader title="Trọng số điểm rủi ro tổng hợp" subtitle={`Tổng phải bằng 1. Hiện tại: ${wSum.toFixed(2)}`} />
        <div className="p-5 grid sm:grid-cols-4 gap-4">
          <F label="Margin Δ" v={p.risk_weights.margin_delta} on={setW('margin_delta')} ro={ro} step={0.05} />
          <F label="Sức khỏe tồn kho" v={p.risk_weights.inventory_health} on={setW('inventory_health')} ro={ro} step={0.05} />
          <F label="Tốc độ bán" v={p.risk_weights.velocity} on={setW('velocity')} ro={ro} step={0.05} />
          <F label="Biến động giá" v={p.risk_weights.volatility} on={setW('volatility')} ro={ro} step={0.05} />
        </div>
      </Card>

      <Card>
        <CardHeader title="Tồn kho & dữ liệu" />
        <div className="p-5 grid sm:grid-cols-4 gap-4">
          <F label="Lead time mặc định" v={p.default_lead_time_days} on={set('default_lead_time_days')} ro={ro} unit="ngày" step={1} />
          <F label="Safety stock" v={p.safety_stock_days} on={set('safety_stock_days')} ro={ro} unit="ngày" step={1} />
          <F label="Gate sẵn sàng dữ liệu" v={p.data_readiness_target_pct} on={set('data_readiness_target_pct')} ro={ro} unit="% doanh thu" />
          <F label="Sai lệch đối soát cho phép" v={p.revenue_tolerance_pct} on={set('revenue_tolerance_pct')} ro={ro} unit="%" step={0.5} />
        </div>
      </Card>

      <Card>
        <CardHeader title="SLA ngoại lệ & rule engine" subtitle="Thời hạn xử lý theo mức ưu tiên; rule tắt sẽ không mở ngoại lệ mới (ngoại lệ cũ tự đóng ở lần chạy kế)." />
        <div className="p-5 grid sm:grid-cols-5 gap-4">
          <F label="SLA P0" v={sla.P0} on={setSla('P0')} ro={ro} unit="giờ" step={1} />
          <F label="SLA P1" v={sla.P1} on={setSla('P1')} ro={ro} unit="giờ" step={1} />
          <F label="SLA P2" v={sla.P2} on={setSla('P2')} ro={ro} unit="giờ" step={1} />
          <F label="SLA P3" v={sla.P3} on={setSla('P3')} ro={ro} unit="giờ" step={1} />
          <F label="Cooldown sau cảnh báo sai" v={p.cooldown_days ?? 7} on={set('cooldown_days')} ro={ro} unit="ngày" step={1} />
        </div>
        <div className="px-5 pb-5 grid sm:grid-cols-2 lg:grid-cols-4 gap-2">
          {Object.entries(RULE_LABEL).map(([code, label]) => (
            <label key={code} className={`flex items-center gap-2 text-sm rounded-lg border px-3 py-2 ${toggles[code] === false ? 'border-gray-200 text-gray-400' : 'border-emerald-200 bg-emerald-50/40 text-gray-800'}`}>
              <input type="checkbox" className="rounded" disabled={ro} checked={toggles[code] !== false} onChange={(e) => setToggle(code, e.target.checked)} />
              <span>{label}<span className="block text-[10px] font-mono text-gray-400">{code}</span></span>
            </label>
          ))}
        </div>
      </Card>

      <Card className="border-red-200">
        <CardHeader title="Tự động hoá có giới hạn (Tuần 11)" subtitle="Mặc định chỉ chạy thử. Canary chỉ áp dụng cho ASIN trong danh sách. Live cần bật công tắc và vẫn bị giới hạn số lệnh/ngày + tự hoàn tác." />
        <div className="p-5 grid sm:grid-cols-4 gap-4">
          <label className="flex items-center gap-2 text-sm sm:col-span-4"><input type="checkbox" className="rounded" disabled={ro} checked={!!p.automation_live} onChange={(e) => setP({ ...p, automation_live: e.target.checked })} /><span><b>Bật chế độ live</b> – lệnh ghi thật ngoài canary (chỉ owner nên bật khi đã qua pilot canary)</span></label>
          <div className="sm:col-span-4">
            <label className="block text-xs font-medium text-gray-700 mb-1">ASIN canary (phân cách bằng dấu phẩy)</label>
            <input value={(p.canary_asins ?? []).join(', ')} disabled={ro} onChange={(e) => setP({ ...p, canary_asins: e.target.value.split(/[,\s]+/).map((x) => x.trim().toUpperCase()).filter(Boolean) })} className={`${input} font-mono disabled:bg-gray-50`} placeholder="B08N5RRNJC, B07XJ8C8F5" />
          </div>
          <F label="Cửa sổ theo dõi" v={p.rollback_watch_hours ?? 48} on={set('rollback_watch_hours')} ro={ro} unit="giờ" step={1} />
          <F label="Tự hoàn tác khi units giảm" v={p.rollback_units_drop_pct ?? 35} on={set('rollback_units_drop_pct')} ro={ro} unit="%" step={1} />
          <F label="Tối đa lệnh thật / ngày" v={p.max_live_actions_per_day ?? 5} on={set('max_live_actions_per_day')} ro={ro} unit="lệnh" step={1} />
        </div>
      </Card>

      {problems.length > 0 && <ErrorBox message={problems.join(' · ')} />}
      {!ro && (
        <div className="flex items-center gap-3">
          <button className={btn.primary} disabled={saving || problems.length > 0} onClick={save}>{saving ? 'Đang lưu…' : 'Lưu chính sách'}</button>
          {saved && <span className="text-sm text-emerald-700">Đã lưu. Cập nhật lúc {new Date().toLocaleTimeString('vi-VN')}.</span>}
          {!saved && <span className="text-xs text-gray-500">Cập nhật lần cuối {new Date(p.updated_at).toLocaleString('vi-VN')}</span>}
        </div>
      )}
    </div>
  );
}

function F({ label, v, on, ro, unit, step = 1 }: { label: string; v: number; on: (e: React.ChangeEvent<HTMLInputElement>) => void; ro: boolean; unit?: string; step?: number }) {
  return (
    <div>
      <label className="block text-xs font-medium text-gray-700 mb-1">{label}</label>
      <div className="flex items-center gap-2">
        <input type="number" step={step} value={v} onChange={on} disabled={ro} className={`${input} tabular-nums disabled:bg-gray-50`} />
        {unit && <span className="text-xs text-gray-500 whitespace-nowrap">{unit}</span>}
      </div>
    </div>
  );
}
function Ladder({ items }: { items: [string, string][] }) {
  return (
    <div className="px-5 pb-5 flex gap-2 text-xs">
      {items.map(([l, r]) => <span key={l} className="px-2 py-1 rounded-md bg-gray-100 text-gray-700"><b>{l}</b> {r}</span>)}
    </div>
  );
}
