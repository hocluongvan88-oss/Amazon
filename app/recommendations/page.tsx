/*
 * Trang danh sách gợi ý cho Vexim Amazon Managed Operations
 * Hiện tại hiển thị placeholder – sẽ được liên kết với API recommendations sau.
 */

export async function metadata() {
  return {
    title: 'Vexim – Gợi ý',
    description: 'Danh sách gợi ý đã tạo cho các ASIN',
  };
}

export default function RecommendationsPage() {
  return (
    <section className="py-8 bg-gray-50">
      <div className="max-w-7xl mx-auto">
        <h1 className="text-3xl font-bold text-gray-900 mb-6">Danh sách gợi ý</h1>
        <p className="text-gray-600 mb-4">
          Gợi ý chưa có dữ liệu. Sau khi chạy pipeline sẽ hiển thị các gợi ý price, inventory và review.
        </p>
        <a href="/" className="btn bg-indigo-600 text-white px-4 py-2 rounded-md hover:bg-indigo-700 transition">
          Quay về bảng điều khiển
        </a>
      </div>
    </section>
  );
}