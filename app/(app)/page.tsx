import type { Metadata } from 'next';
import Dashboard from './Dashboard';

export const metadata: Metadata = { title: 'Tổng quan' };

export default function Page() {
  return <Dashboard />;
}
