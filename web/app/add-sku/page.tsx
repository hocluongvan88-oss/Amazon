/*
 * Trang thêm SKU mới cho Vexim Amazon Managed Operations
 * Form mẫu sẵn sàng – sẽ tích hợp với Supabase sau.
 */

export async function metadata() {
  return {
    title: 'Vexim – Thêm SKU mới',
    description: 'Trang nhập thông tin ASIN/SKU mới cho pilot',
  };
}

export default function AddSkuPage() {
  return (
    <section className="py-8 bg-gray-50">
      <div className="max-w-2xl mx-auto space-y-6">
        <h1 className="text-3xl font-bold text-gray-900">Thêm SKU mới</h1>

        <form className="bg-white p-6 rounded-lg shadow-sm border border-gray-200">
          <div className="grid grid-cols-1 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">ASIN</label>
              <input
                type="text"
                placeholder="Ví dụ: B08N5RRNJC"
                className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
                required
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Tên sản phẩm</label>
              <input
                type="text"
                placeholder="Tên sản phẩm"
                className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
                required
              />
            </div>
          </div>

          <div className="grid grid-cols-1 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">COGS (USD)</label>
              <input
                type="number"
                placeholder="0.00"
                className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
                required
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Giá bán hiện tại (USD)</label>
              <input
                type="number"
                placeholder="0.00"
                className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
                required
              />
            </div>
          </div>

          <button
            type="submit"
            className="w-full bg-green-600 text-white px-4 py-2 rounded-md hover:bg-green-700 transition font-medium">
            Lưu SKU
          </button>
        </form>

        <a href="/" className="text-sm text-blue-600 underline">
          Quay về bảng điều khiển
        </a>
      </div>
    </section>
  );
}