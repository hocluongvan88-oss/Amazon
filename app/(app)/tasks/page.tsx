import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import TasksQueue from './TasksQueue';

export const metadata: Metadata = { title: 'Hàng đợi task' };

export default function TasksPage() {
  return (
    <>
      <PageHeader title="Hàng đợi task" description="Mọi việc sinh ra từ VoC, listing audit, exception: content · QA sản phẩm · ads guardrail · CSKH · điều tra tồn kho. Đóng task bắt buộc ghi kết quả." />
      <TasksQueue />
    </>
  );
}
