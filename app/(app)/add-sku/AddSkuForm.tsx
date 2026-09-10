'use client';

import React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';
import { usd } from '@/lib/format';
import { Card, CardHeader, btn, input, ErrorBox } from '@/components/ui';
import { useTenant } from '@/lib/tenant';

type Form = {
  asin: string; sku: string; title: string;
  cogs: string; current_price: string; fee_per_unit: string; referral_fee_pct: string;
  inventory_qty: string; reorder_point: string; sales_last_30d: string;
};

const initial: Form = {
  asin: '', sku: '', title: '', cogs: '', current_price: '', fee_per_unit: '0', referral_fee_pct: '15',
  inventory_qty: '0', reorder_point: '0', sales_last_30d: '0',
};

export default function AddSkuForm() {
  const router = useRouter();
  const { tenant, canWrite } = useTenant();
  const [f, setF] = React.useState<Form>(initial);
  const [saving, setSaving] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const set = (k: keyof Form) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });
  const n = (k: keyof Form) => Number(f[k] || 0);

  // live preview
  const price = n('current_price');
  const cp = price - n('cogs') - n('fee_per_unit') - (price * n('referral_fee_pct')) / 100;
  const margin = price ? (cp / price) * 100 : 0;
  const sales = n('sales_last_30d');
  const cover = sales > 0 ? n('inventory_qty') / (sales / 30) : null;

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!tenant) return;
    setError(null); setSaving(true);
    const { error: e2 } = await supabase.from('amazon_skus').insert({
      tenant_id: tenant.id, marketplace: tenant.marketplace,
      asin: f.asin.trim().toUpperCase(), sku: f.sku.trim() || null, title: f.title.trim(),
      cogs: n('cogs'), current_price: price, fee_per_unit: n('fee_per_unit'),
      referral_fee_pct: n('referral_fee_pct') || 15, inventory_qty: n('inventory_qty'),
      reorder_point: n('reorder_point'), sales_last_30d: sales,
    });
    setSaving(false);
    if (e2) { setError(e2.code === '23505' ? 'ASIN này đã có trong danh mục.' : e2.message); return; }
    router.push('/'); router.refresh();
  }

  if (tenant && !canWrite) return <ErrorBox message="Vai trò Viewer không được thêm SKU." />;

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <div className="lg:col-span-2 space-y-6">
        <Card>
          <CardHeader title="Thông tin sản phẩm" />
          <div className="p-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="ASIN" required hint="10 ký tự, ví dụ B08N5RRNJC">
              <input required pattern="[A-Za-z0-9]{10}" value={f.asin} onChange={set('asin')} className={`${input} font-mono uppercase`} placeholder="B08N5RRNJC" />
            </Field>
            <Field label="SKU nội bộ" hint="Tuỳ chọn">
              <input value={f.sku} onChange={set('sku')} className={`${input} font-mono`} placeholder="VX-XXX-01" />
            </Field>
            <div className="sm:col-span-2">
              <Field label="Tên sản phẩm" required>
                <input required value={f.title} onChange={set('title')} className={input} placeholder="Tên hiển thị trên Amazon" />
              </Field>
            </div>
          </div>
        </Card>

        <Card>
          <CardHeader title="Giá & chi phí" subtitle="Dùng để tính lợi nhuận góp phần mỗi đơn vị" />
          <div className="p-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Field label="Giá bán hiện tại (USD)" required><Num value={f.current_price} onChange={set('current_price')} required /></Field>
            <Field label="COGS – giá vốn (USD)" required><Num value={f.cogs} onChange={set('cogs')} required /></Field>
            <Field label="Phí FBA / đơn vị (USD)" hint="Pick & pack + vận chuyển"><Num value={f.fee_per_unit} onChange={set('fee_per_unit')} /></Field>
            <Field label="Phí referral (%)" hint="Thường 8–15% theo ngành hàng"><Num value={f.referral_fee_pct} onChange={set('referral_fee_pct')} max={100} /></Field>
          </div>
        </Card>

        <Card>
          <CardHeader title="Tồn kho & bán hàng" subtitle="Dùng để tính ngày hàng còn lại và rủi ro hết hàng" />
          <div className="p-5 grid grid-cols-1 sm:grid-cols-3 gap-4">
            <Field label="Tồn kho hiện tại (đv)"><Num value={f.inventory_qty} onChange={set('inventory_qty')} step={1} /></Field>
            <Field label="Điểm đặt hàng lại (đv)" hint="Dưới mức này → cần nhập thêm"><Num value={f.reorder_point} onChange={set('reorder_point')} step={1} /></Field>
            <Field label="Doanh số 30 ngày (đv)"><Num value={f.sales_last_30d} onChange={set('sales_last_30d')} step={1} /></Field>
          </div>
        </Card>
      </div>

      <div className="space-y-4 lg:sticky lg:top-6 self-start">
        <Card>
          <CardHeader title="Xem trước chỉ số" />
          <dl className="p-5 space-y-3 text-sm">
            <Row k="LN góp phần / đơn vị" v={usd(cp)} cls={cp < 0 ? 'text-red-600' : 'text-emerald-700'} />
            <Row k="Biên LN góp phần" v={`${margin.toFixed(1)}%`} cls={margin < 15 ? 'text-orange-600' : ''} />
            <Row k="LN góp phần 30 ngày" v={usd(cp * sales, 0)} />
            <Row k="Ngày hàng còn lại" v={cover == null ? '—' : `${cover.toFixed(0)} ngày`} cls={cover != null && cover < 21 ? 'text-red-600' : ''} />
          </dl>
          <div className="px-5 pb-5 text-xs text-gray-500">
            Công thức: giá − COGS − phí FBA − giá × referral%.
          </div>
        </Card>

        {error && <div className="rounded-lg bg-red-50 border border-red-200 p-3 text-sm text-red-700">{error}</div>}

        <div className="flex gap-2">
          <button type="submit" disabled={saving} className={`${btn.primary} flex-1 justify-center`}>{saving ? 'Đang lưu…' : 'Lưu SKU'}</button>
          <Link href="/" className={btn.secondary}>Huỷ</Link>
        </div>
      </div>
    </form>
  );
}

function Field({ label, hint, required, children }: { label: string; hint?: string; required?: boolean; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-sm font-medium text-gray-700 mb-1">{label}{required && <span className="text-red-500"> *</span>}</label>
      {children}
      {hint && <p className="text-xs text-gray-500 mt-1">{hint}</p>}
    </div>
  );
}
function Num(props: { value: string; onChange: (e: React.ChangeEvent<HTMLInputElement>) => void; required?: boolean; step?: number; max?: number }) {
  return <input type="number" inputMode="decimal" min={0} step={props.step ?? 0.01} max={props.max} required={props.required}
    value={props.value} onChange={props.onChange} className={`${input} tabular-nums`} placeholder="0" />;
}
function Row({ k, v, cls = '' }: { k: string; v: string; cls?: string }) {
  return <div className="flex justify-between gap-4"><dt className="text-gray-500">{k}</dt><dd className={`font-semibold tabular-nums ${cls}`}>{v}</dd></div>;
}
