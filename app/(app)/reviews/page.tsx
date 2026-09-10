import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import ReviewsVoc from './ReviewsVoc';

export const metadata: Metadata = { title: 'Review / VOC' };

export default function ReviewsPage() {
  return (
    <>
      <PageHeader
        title="Đánh giá & Voice of Customer"
        description="Lắng nghe & xử lý: chủ đề khách nhắc đến theo ASIN, đánh giá tiêu cực 1–3★ cần xử lý, ticket VOC cho QC/listing/fulfillment, tin liên hệ khách hàng qua Brand Registry có kiểm tra chính sách và người duyệt. Đánh giá tích cực dùng để khai thác điểm mạnh cho listing & quảng cáo – không có hành động nào tác động đến rating."
      />
      <ReviewsVoc />
    </>
  );
}
