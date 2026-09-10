import type { Metadata } from 'next';
import PolicyForm from './PolicyForm';
import PageHeader from '@/components/PageHeader';

export const metadata: Metadata = { title: 'Chính sách' };

export default function PolicyPage() {
  return (
    <>
      <PageHeader
        title="Chính sách & ngưỡng"
        description="Policy register của brand: quyết định gợi ý nào được tự động (L0), cần operator (L1) hay owner (L2); ngưỡng cảnh báo P0–P3; giới hạn đổi giá. Mọi thay đổi được ghi nhật ký."
      />
      <PolicyForm />
    </>
  );
}
