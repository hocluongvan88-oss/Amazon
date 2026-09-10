import type { Metadata } from 'next';
import MembersManager from './MembersManager';
import PageHeader from '@/components/PageHeader';

export const metadata: Metadata = { title: 'Thành viên' };

export default function MembersPage() {
  return (
    <>
      <PageHeader title="Thành viên & vai trò" description="Owner: mọi quyền, duyệt L2. Operator: tạo/sửa SKU, gửi & duyệt gợi ý L0–L1. Viewer: chỉ xem." />
      <MembersManager />
    </>
  );
}
