import type { Metadata } from 'next';
import PageHeader from '@/components/PageHeader';
import ProfitBridge from './ProfitBridge';

export const metadata: Metadata = { title: 'Profit bridge' };

export default function ProfitBridgePage() {
  return (
    <>
      <PageHeader
        title="Profit bridge"
        description="Lợi nhuận đóng góp thay đổi vì đâu: sản lượng, giá, giá vốn, phí hay quảng cáo. So kỳ này với kỳ liền trước."
      />
      <ProfitBridge />
    </>
  );
}
