import type { Metadata } from 'next';
import AuditList from './AuditList';
import PageHeader from '@/components/PageHeader';

export const metadata: Metadata = { title: 'Nhật ký' };

export default function AuditPage() {
  return (
    <>
      <PageHeader title="Nhật ký hành động" description="Mọi thay đổi trên SKU, gợi ý và ngoại lệ được ghi tự động: ai, khi nào, thay đổi gì. Không thể sửa hay xoá." />
      <AuditList />
    </>
  );
}
