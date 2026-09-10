import Link from 'next/link';
import type { Metadata } from 'next';
import RecommendationsList from './RecommendationsList';

export const metadata: Metadata = {
  title: 'Vexim – Gợi ý',
  description: 'Danh sách gợi ý đã tạo cho các ASIN',
};

export default function RecommendationsPage() {
  return (
    <section className="py-8 bg-gray-50 flex-1">
      <div className="max-w-7xl mx-auto px-4">
        <header className="mb-6 flex items-center justify-between flex-col sm:flex-row gap-4">
          <h1 className="text-3xl font-bold text-gray-900">Danh sách gợi ý</h1>
          <Link href="/" className="px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700 transition">
            Quay về bảng điều khiển
          </Link>
        </header>
        <RecommendationsList />
      </div>
    </section>
  );
}
