import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import ContentStudio from './ContentStudio';

export const metadata: Metadata = { title: 'Content Studio' };

export default function ContentPage() {
  return (
    <>
      <PageHeader
        title="Content & Listing Studio"
        description="Product Facts → draft (title / bullets / mô tả / backend / A+) → Compliance Gate → QA → Brand duyệt → ghi nhận publish → đo CVR trước/sau. Mọi claim phải trỏ về fact đã xác minh. Chưa có write‑back Amazon: publish là ghi nhận thủ công."
      />
      <ContentStudio />
    </>
  );
}
