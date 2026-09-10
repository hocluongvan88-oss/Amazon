import type { Metadata } from 'next';
import SkuDetail from './SkuDetail';

export const metadata: Metadata = { title: 'Chi tiết ASIN' };

export default async function SkuPage({ params }: PageProps<'/skus/[id]'>) {
  const { id } = await params;
  return <SkuDetail id={id} />;
}
