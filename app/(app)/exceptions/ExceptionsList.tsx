'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { Card, Badge, EmptyState, Spinner, ErrorBox, btn } from '@/components/ui';
import { useTenant } from '@/lib/tenant';

type Exc = {
  id: string; code: string; message: string; asin: string | null; resolved: boolean;
  created_at: string; recommendation_id: string | null;
  recommendations: { title: string | null; status: string } | null;
};

const CODE_CLS: Record<string, string> = {
  P0: 'bg-red-600 text-white ring-red-700',
  P1: 'bg-red-50 text-red-700 ring-red-600/20',
  P2: 'bg-yellow-50 text-yellow-800 ring-yellow-600/20',
  P3: 'bg-gray-50 text-gray-700 ring-gray-500/20',
};

export default function ExceptionsList() {
  const { tenant, canWrite } = useTenant();
  const [items, setItems] = React.useState<Exc[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [showResolved, setShowResolved] = React.useState(false);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const { data, error: e } = await supabase
      .from('exceptions')
      .select('*, recommendations(title,status)')
      .eq('tenant_id', tenant.id)
      .order('resolved').order('code').order('created_at', { ascending: false });
    if (e) setError(e.message); else setItems((data ?? []) as Exc[]);
    setLoading(false);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on mount
    void load();
  }, [load]);

  async function resolve(id: string, resolved: boolean) {
    const { error: e } = await supabase.from('exceptions')
      .update({ resolved, resolved_at: resolved ? new Date().toISOString() : null }).eq('id', id);
    if (e) setError(e.message); else load();
  }

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  const list = items.filter((i) => showResolved || !i.resolved);

  return (
    <>
      <label className="inline-flex items-center gap-2 text-sm text-gray-700 mb-4">
        <input type="checkbox" checked={showResolved} onChange={(e) => setShowResolved(e.target.checked)} className="rounded" />
        Hiện cả ngoại lệ đã xử lý
      </label>
      <Card>
        {list.length === 0 ? (
          <EmptyState title="Không có ngoại lệ nào" description="Mọi thứ đang trong ngưỡng chính sách." />
        ) : (
          <ul className="divide-y divide-gray-100">
            {list.map((e) => (
              <li key={e.id} className={`px-5 py-4 flex flex-col sm:flex-row sm:items-center gap-3 ${e.resolved ? 'opacity-60' : ''}`}>
                <Badge className={CODE_CLS[e.code] ?? CODE_CLS.P3}>{e.code}</Badge>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-gray-900">{e.message}</p>
                  <p className="text-xs text-gray-500">
                    {e.asin && <span className="font-mono">{e.asin}</span>}
                    {e.recommendations?.title && <> · Gợi ý: {e.recommendations.title}</>}
                    {' · '}{new Date(e.created_at).toLocaleString('vi-VN')}
                  </p>
                </div>
                <div className="flex gap-2 shrink-0">
                  {e.asin && <Link href={`/recommendations?asin=${e.asin}`} className={btn.secondary}>Xem gợi ý</Link>}
                  {canWrite && (e.resolved
                    ? <button className={btn.secondary} onClick={() => resolve(e.id, false)}>Mở lại</button>
                    : <button className={btn.success} onClick={() => resolve(e.id, true)}>✓ Đã xử lý</button>)}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </>
  );
}
