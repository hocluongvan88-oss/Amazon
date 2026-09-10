'use client';

import React from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';

const inputCls =
  'w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500';

export default function AddSkuForm() {
  const router = useRouter();
  const [saving, setSaving] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    const fd = new FormData(e.currentTarget);
    const num = (k: string) => Number(fd.get(k) || 0);

    const { error: insertError } = await supabase.from('amazon_skus').insert({
      asin: String(fd.get('asin')).trim().toUpperCase(),
      sku: String(fd.get('sku') || '').trim() || null,
      title: String(fd.get('title')).trim(),
      cogs: num('cogs'),
      current_price: num('current_price'),
      fee_per_unit: num('fee_per_unit'),
      referral_fee_pct: num('referral_fee_pct') || 15,
      inventory_qty: num('inventory_qty'),
      reorder_point: num('reorder_point'),
      sales_last_30d: num('sales_last_30d'),
    });

    setSaving(false);
    if (insertError) {
      setError(
        insertError.code === '23505'
          ? 'ASIN này đã tồn tại.'
          : insertError.message
      );
      return;
    }
    router.push('/');
    router.refresh();
  }

  return (
    <form onSubmit={onSubmit} className="bg-white p-6 rounded-lg shadow-sm border border-gray-200 space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Field label="ASIN *">
          <input name="asin" required pattern="[A-Za-z0-9]{10}" placeholder="B08N5RRNJC" className={inputCls} />
        </Field>
        <Field label="SKU nội bộ">
          <input name="sku" placeholder="VX-XXX-01" className={inputCls} />
        </Field>
      </div>
      <Field label="Tên sản phẩm *">
        <input name="title" required placeholder="Tên sản phẩm" className={inputCls} />
      </Field>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Field label="COGS (USD) *">
          <input name="cogs" type="number" step="0.01" min="0" required className={inputCls} />
        </Field>
        <Field label="Giá bán hiện tại (USD) *">
          <input name="current_price" type="number" step="0.01" min="0" required className={inputCls} />
        </Field>
        <Field label="Phí FBA / đơn vị (USD)">
          <input name="fee_per_unit" type="number" step="0.01" min="0" defaultValue={0} className={inputCls} />
        </Field>
        <Field label="Phí referral (%)">
          <input name="referral_fee_pct" type="number" step="0.01" min="0" max="100" defaultValue={15} className={inputCls} />
        </Field>
        <Field label="Tồn kho hiện tại">
          <input name="inventory_qty" type="number" min="0" defaultValue={0} className={inputCls} />
        </Field>
        <Field label="Điểm đặt hàng lại">
          <input name="reorder_point" type="number" min="0" defaultValue={0} className={inputCls} />
        </Field>
        <Field label="Doanh số 30 ngày (đơn vị)">
          <input name="sales_last_30d" type="number" min="0" defaultValue={0} className={inputCls} />
        </Field>
      </div>

      {error && <p className="text-sm text-red-600">Lỗi: {error}</p>}

      <button
        type="submit"
        disabled={saving}
        className="w-full bg-green-600 text-white px-4 py-2 rounded-md hover:bg-green-700 transition font-medium disabled:opacity-60"
      >
        {saving ? 'Đang lưu…' : 'Lưu SKU'}
      </button>
    </form>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-sm font-medium text-gray-700 mb-1">{label}</label>
      {children}
    </div>
  );
}
