import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import ActionsLog from './ActionsLog';

export const metadata: Metadata = { title: 'Lệnh thực thi' };

export default function ActionsPage() {
  return (
    <>
      <PageHeader
        title="Lệnh thực thi & hoàn tác"
        description="Mọi thay đổi ra Amazon đều đi qua đây: chạy thử → canary → live, khoá idempotency, cửa sổ theo dõi và tự hoàn tác. Gate tuần 11: 0 lệnh ngoài kiểm soát."
      />
      <ActionsLog />
    </>
  );
}
