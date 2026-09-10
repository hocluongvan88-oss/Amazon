import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import ReviewsVoc from './ReviewsVoc';

export const metadata: Metadata = { title: 'Review / VOC' };

export default function ReviewsPage() {
  return (
    <>
      <PageHeader
        title="Review & tiếng nói khách hàng"
        description="Lắng nghe và phân loại: cụm chủ đề theo ASIN, triage review sao thấp, ticket VOC, nháp phản hồi có kiểm tra chính sách và người duyệt. Không có hành động nào tác động đến rating."
      />
      <ReviewsVoc />
    </>
  );
}
