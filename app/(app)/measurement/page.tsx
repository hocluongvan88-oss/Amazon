import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import Measurement from './Measurement';

export const metadata: Metadata = { title: 'Đo lường' };

export default function MeasurementPage() {
  return (
    <>
      <PageHeader
        title="Đo lường & quyết định pilot"
        description="Bốn bằng chứng để quyết định mở rộng: dữ liệu đã đối soát · operator dùng workflow · hành động tạo tác động (incremental CP có khoảng tin cậy) · 0 sự cố. Xuất báo cáo pilot có dấu thời gian."
      />
      <Measurement />
    </>
  );
}
