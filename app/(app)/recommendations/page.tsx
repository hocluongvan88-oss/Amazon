import type { Metadata } from 'next';
import { Suspense } from 'react';
import RecommendationsList from './RecommendationsList';
import PageHeader from '@/components/PageHeader';
import { Spinner } from '@/components/ui';

export const metadata: Metadata = { title: 'Gợi ý & phê duyệt' };

export default function RecommendationsPage() {
  return (
    <>
      <PageHeader
        title="Gợi ý & phê duyệt"
        description="Các đề xuất do hệ thống sinh ra về giá, nhập hàng, chuyển kho và phản hồi review. Duyệt theo cấp: L0 tự động · L1 operator · L2 admin."
      />
      <Suspense fallback={<Spinner />}>
        <RecommendationsList />
      </Suspense>
    </>
  );
}
