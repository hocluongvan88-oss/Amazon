'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { REC_STATUS } from '@/lib/format';
import { Card, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Row = {
  id: number; actor_email: string | null; entity_type: string; entity_id: string | null;
  action: string; payload: Record<string, unknown> | null; after: Record<string, unknown> | null; created_at: string;
};

const ENTITY: Record<string, string> = { amazon_skus: 'SKU', recommendations: 'Gợi ý', exceptions: 'Ngoại lệ' };
const HIDE = new Set(['updated_at', 'created_at', 'tenant_id', 'id']);

function describe(r: Row) {
  const a = r.action;
  if (a.startsWith('status:')) return { label: `→ ${REC_STATUS[a.slice(7)]?.label ?? a.slice(7)}`, cls: 'bg-indigo-50 text-indigo-700 ring-indigo-600/20' };
  const map: Record<string, [string, string]> = {
    insert: ['Tạo mới', 'bg-emerald-50 text-emerald-700 ring-emerald-600/20'],
    update: ['Cập nhật', 'bg-gray-50 text-gray-700 ring-gray-500/20'],
    delete: ['Xoá', 'bg-red-50 text-red-700 ring-red-600/20'],
    resolve: ['Đã xử lý', 'bg-emerald-50 text-emerald-700 ring-emerald-600/20'],
    reopen: ['Mở lại', 'bg-yellow-50 text-yellow-800 ring-yellow-600/20'],
  };
  const [label, cls] = map[a] ?? [a, 'bg-gray-50 text-gray-700 ring-gray-500/20'];
  return { label, cls };
}

export default function AuditList() {
  const { tenant } = useTenant();
  const [rows, setRows] = React.useState<Row[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [q, setQ] = React.useState('');
  const [entity, setEntity] = React.useState('all');
  const PAGE = 100;
  const [limit, setLimit] = React.useState(PAGE);

  React.useEffect(() => {
    if (!tenant) return;
    let cancelled = false;
    (async () => {
      const { data, error: e } = await supabase
        .from('audit_log').select('id,actor_email,entity_type,entity_id,action,payload,after,created_at')
        .eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(limit);
      if (cancelled) return;
      if (e) setError(e.message); else setRows((data ?? []) as Row[]);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, [tenant, limit]);

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  const list = rows
    .filter((r) => entity === 'all' || r.entity_type === entity)
    .filter((r) => {
      const t = q.trim().toLowerCase();
      if (!t) return true;
      const hay = `${r.actor_email ?? ''} ${r.action} ${JSON.stringify(r.after ?? {})}`.toLowerCase();
      return hay.includes(t);
    });

  return (
    <>
      <div className="flex flex-wrap gap-2 mb-4">
        <select value={entity} onChange={(e) => setEntity(e.target.value)} className={`${input} w-40`}>
          <option value="all">Mọi đối tượng</option>
          {Object.entries(ENTITY).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Tìm email, ASIN, nội dung…" className={`${input} w-64`} />
      </div>
      <Card>
        {list.length === 0 ? <EmptyState title="Chưa có bản ghi" /> : (
          <ul className="divide-y divide-gray-100">
            {list.map((r) => {
              const d = describe(r);
              const after = r.after ?? {};
              const label = (after.title as string) ?? (after.message as string) ?? (after.asin as string) ?? r.entity_id?.slice(0, 8);
              const changes = r.payload ? Object.entries(r.payload).filter(([k]) => !HIDE.has(k)) : [];
              return (
                <li key={r.id} className="px-5 py-3 text-sm">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-xs text-gray-400 tabular-nums w-36">{new Date(r.created_at).toLocaleString('vi-VN')}</span>
                    <span className="font-medium text-gray-800">{r.actor_email ?? 'hệ thống'}</span>
                    <Badge className={d.cls}>{d.label}</Badge>
                    <span className="text-gray-500">{ENTITY[r.entity_type] ?? r.entity_type}</span>
                    <span className="text-gray-900 truncate max-w-md">{label}</span>
                    {after.asin && after.title ? <span className="font-mono text-xs text-gray-400">{after.asin as string}</span> : null}
                  </div>
                  {changes.length > 0 && r.action === 'update' && (
                    <p className="mt-1 ml-38 text-xs text-gray-500 truncate">
                      {changes.slice(0, 6).map(([k, v]) => `${k} = ${typeof v === 'object' ? JSON.stringify(v) : String(v)}`).join(' · ')}
                    </p>
                  )}
                </li>
              );
            })}
          </ul>
        )}
        {rows.length >= limit && (
          <div className="p-4 text-center border-t border-gray-100">
            <button className={btn.secondary} onClick={() => setLimit(limit + PAGE)}>Tải thêm</button>
          </div>
        )}
      </Card>
    </>
  );
}
