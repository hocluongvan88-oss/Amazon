import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import DataSources from './DataSources';

export const metadata: Metadata = { title: 'Nguồn dữ liệu' };

export default function DataSourcesPage() {
  return (
    <>
      <PageHeader
        title="Nguồn dữ liệu & độ tươi"
        description="Mọi nguồn (CSV, SP‑API, Ads API) đi qua cùng một mô hình: nguồn → lần lấy dữ liệu → bảng chuẩn hoá. CSV là bootstrap; API là kiến trúc chính. Feed quá SLA sẽ được gắn cờ và cảnh báo trên Tổng quan & Control Room."
      />
      <DataSources />
    </>
  );
}
