import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import InventoryPlanner from './InventoryPlanner';

export const metadata: Metadata = { title: 'Tồn kho' };

export default function InventoryPage() {
  return (
    <>
      <PageHeader
        title="Tồn kho & bổ sung hàng"
        description="Dự báo bán ra theo ASIN, ngày hết hàng, thời điểm phải đặt hàng và số lượng đề xuất. Kéo lead time / ngày an toàn để xem kịch bản."
      />
      <InventoryPlanner />
    </>
  );
}
