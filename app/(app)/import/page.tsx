import type { Metadata } from 'next';
import ImportWizard from './ImportWizard';
import Reconciliation from './Reconciliation';
import PageHeader from '@/components/PageHeader';

export const metadata: Metadata = { title: 'Nhập dữ liệu' };

export default function ImportPage() {
  return (
    <>
      <PageHeader
        title="Nhập dữ liệu (CSV)"
        description="Nguồn dữ liệu chính thức cho pilot: export từ Seller Central và file kế toán. Không dùng scraping. Mỗi lần import được ghi lại kèm số dòng lỗi."
      />
      <ImportWizard />
      <div className="mt-6"><Reconciliation /></div>
    </>
  );
}
