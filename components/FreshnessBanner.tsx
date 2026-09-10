'use client';

import React from 'react';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';

export type FreshnessSummary = {
  fresh: number; stale: number; missing: number; required_ok: boolean | null;
  problems: { feed: string; label: string; status: 'stale' | 'missing'; age_hours: number | null; required: boolean }[];
};

/** Banner độ tươi dữ liệu — hiện khi có feed bắt buộc stale/missing. Ẩn hoàn toàn nếu chưa chạy 015. */
export default function FreshnessBanner({ tenantId, compact = false }: { tenantId: string | null | undefined; compact?: boolean }) {
  const [sum, setSum] = React.useState<FreshnessSummary | null>(null);

  React.useEffect(() => {
    if (!tenantId) return;
    (async () => {
      const { data, error } = await supabase.rpc('freshness_summary', { t: tenantId });
      if (!error && data) setSum(data as FreshnessSummary);
    })();
  }, [tenantId]);

  if (!sum || sum.required_ok) return null;
  const req = sum.problems.filter((p) => p.required);
  const other = sum.problems.filter((p) => !p.required);
  return (
    <div className={`rounded-lg border border-amber-300 bg-amber-50 text-amber-900 ${compact ? 'px-3 py-2 text-xs' : 'px-4 py-3 text-sm'} mb-4`}>
      <p className="font-medium">
        ⚠ Dữ liệu chưa tươi — {req.length} feed bắt buộc {req.some((p) => p.status === 'missing') ? 'thiếu/quá hạn' : 'quá hạn SLA'}
        {other.length ? ` · ${other.length} feed khác cần chú ý` : ''}.
        {' '}Gợi ý & đo lường dựa trên số liệu này có thể sai lệch.
      </p>
      {!compact && (
        <ul className="mt-1 flex flex-wrap gap-2">
          {sum.problems.map((p) => (
            <li key={p.feed} className={`rounded-full border px-2 py-0.5 text-xs ${p.required ? 'border-amber-400 bg-white' : 'border-amber-200 bg-amber-100/60'}`}>
              {p.label}: {p.status === 'missing' ? 'chưa có' : `${Math.round(p.age_hours ?? 0)}h`}
            </li>
          ))}
        </ul>
      )}
      <p className="mt-1">
        <Link href="/settings/data-sources" className="underline">Xem nguồn dữ liệu & độ tươi →</Link>
        {' · '}
        <Link href="/import" className="underline">Nhập CSV</Link>
      </p>
    </div>
  );
}
