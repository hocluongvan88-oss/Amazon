import type { Metadata } from 'next';
import ExceptionsList from './ExceptionsList';
import PageHeader from '@/components/PageHeader';

export const metadata: Metadata = { title: 'Ngoại lệ' };

export default function ExceptionsPage() {
  return (
    <>
      <PageHeader
        title="Hàng đợi ngoại lệ"
        description="Cảnh báo vi phạm chính sách hoặc tình huống cần con người can thiệp. P0 khẩn cấp → P3 thấp."
      />
      <ExceptionsList />
    </>
  );
}
