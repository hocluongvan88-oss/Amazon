import Link from 'next/link';
import type { Metadata } from 'next';
import AddSkuForm from './AddSkuForm';

export const metadata: Metadata = {
  title: 'Vexim – Thêm SKU mới',
  description: 'Trang nhập thông tin ASIN/SKU mới cho pilot',
};

export default function AddSkuPage() {
  return (
    <section className="py-8 bg-gray-50 flex-1">
      <div className="max-w-2xl mx-auto px-4 space-y-6">
        <h1 className="text-3xl font-bold text-gray-900">Thêm SKU mới</h1>
        <AddSkuForm />
        <Link href="/" className="text-sm text-blue-600 underline">
          Quay về bảng điều khiển
        </Link>
      </div>
    </section>
  );
}
