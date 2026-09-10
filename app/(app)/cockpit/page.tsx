import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import Cockpit from './Cockpit';

export const metadata: Metadata = { title: 'Cockpit vận hành' };

export default function CockpitPage() {
  return (
    <>
      <PageHeader
        title="Cockpit vận hành hằng ngày"
        description="9 nhóm tín hiệu · so với baseline 30 ngày trước · badge độ tươi dữ liệu · hàng đợi P0–P3 có bằng chứng. Thiếu dữ liệu hiển thị là “—”, không bao giờ là 0. Không có hành động nào tự chạy lên Amazon."
      />
      <Cockpit />
    </>
  );
}
