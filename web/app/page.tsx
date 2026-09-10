'use client';

import React from 'react';

/*
 * Trangdashboard Vexim Amazon Managed Operations
 * Hiện đại, thân thiện người dùng, bố cục rõ ràng – 100% tiếng Việt.
 */

import { supabase } from '@/lib/supabase/client';

export default function DashboardPage() {
  const [skus, setSkus] = React.useState<any[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    async function fetchSkus() {
      try {
        const { data, error: fetchError } = await supabase
          .from('amazon_skus')
          .select('*')
          .order('contribution_profit', { ascending: false });

        if (fetchError) throw fetchError;
        setSkus(data ?? []);
      } catch (e: any) {
        setError(e.message);
      } finally {
        setLoading(false);
      }
    }
    fetchSkus();
  }, []);

  if (loading) return <p>Đang tải dữ liệu…</p>;
  if (error) return <p style={{ color: 'red' }}>Lỗi: {error}</p>;

  return (
    <section className="py-8 bg-gray-50">
      {/* Header hiện đại */}
      <header className="max-w-7xl mx-auto mb-6 flex items-center justify-between flex-col sm:flex-row gap-4">
        <h1 className="text-3xl font-bold text-gray-900">Bảng điều khiển Vexim</h1>
        <nav className="flex items-center gap-3">
          <a href="/recommendations" className="px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700 transition">
            Xem các gợi ý
          </a>
          <a href="/add-sku" className="px-4 py-2 bg-green-600 text-white rounded-md hover:bg-green-700 transition">
            Thêm SKU mới
          </a>
        </nav>
      </header>

      {/* Khối thống kê nhanh (cards) */}
      <div className="max-w-7xl mx-auto grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        {/* Ví dụ card count có thể mở rộng sau khi đếm */}
        <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
          <p className="text-sm text-gray-500">Tổng ASIN</p>
          <p className="text-3xl font-bold text-gray-900">{skus.length}</p>
        </div>
        <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
          <p className="text-sm text-gray-500">Lợi nhuận góp phần tổng</p>
          <p className="text-3xl font-bold text-green-600">
            {(skus.reduce((sum: number, s: any) => sum + (s.contribution_profit ?? 0), 0) as number).toFixed(2)}
          </p>
        </div>
        <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
          <p className="text-sm text-gray-500">TB risk tồn kho</p>
          <p className="text-3xl font-bold text-orange-600">
            {(skus.length > 0
              ? (skus.reduce((sum: number, s: any) => sum + (s.stockout_risk_score ?? 0), 0) / skus.length) as number
              : 0).toFixed(1)}
          </p>
        </div>
        <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
          <p className="text-sm text-gray-500">Đã chọn</p>
          <p className="text-3xl font-bold text-blue-600">{/* placeholder */}</p>
        </div>
      </div>

      {/* Bảng danh sách ASIN */}
      <div className="max-w-7xl mx-auto bg-white rounded-lg shadow-xl overflow-hidden border border-gray-200">
        <table className="w-full text-sm text-gray-700">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                ASIN
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Tên sản phẩm
              </th>
              <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                Lợi nhuận góp phần (USD)
              </th>
              <th className="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                Rủi ro tồn kho
              </th>
              <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                Hành động
              </th>
            </tr>
          </thead>
          <tbody>
            {skus.map((sku) => (
              <tr key={sku.id} className="hover:bg-gray-50 transition">
                <td className="px-6 py-4 font-medium text-gray-900">{sku.asin}</td>
                <td className="px-6 py-4 truncate text-gray-700">{sku.title}</td>
                <td className="px-6 py-4 text-right font-medium text-gray-900">
                  {sku.contribution_profit?.toFixed(2) || '—'}
                </td>
                <td className="px-6 py-4 text-center">
                  {sku.stockout_risk_score?.toFixed(1) || '—'}
                </td>
                <td className="px-6 py-4 text-right">
                  <button
                    className="px-3 py-1.5 text-sm font-medium text-blue-600 underline hover:text-indigo-600"
                    onClick={() => window.open(`/recommendations/${sku.id}`, '_blank')}
                  >
                    Tạo gợi ý
                  </button>
                </td>
              </tr>
            ))}
            {skus.length === 0 && (
              <tr>
                <td colSpan={5} className="px-6 py-8 text-center text-gray-500">
                  Chưa có ASIN. <a href="/add-sku" className="text-blue-600 underline">Thêm SKU đầu tiên</a>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}