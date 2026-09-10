import type { Metadata } from 'next';
import AddSkuForm from './AddSkuForm';
import PageHeader from '@/components/PageHeader';

export const metadata: Metadata = { title: 'Thêm SKU' };

export default function AddSkuPage() {
  return (
    <>
      <PageHeader
        title="Thêm SKU mới"
        description="Đưa một ASIN vào danh mục theo dõi. Lợi nhuận góp phần và rủi ro sẽ được tính tự động từ các số liệu bạn nhập."
      />
      <AddSkuForm />
    </>
  );
}
