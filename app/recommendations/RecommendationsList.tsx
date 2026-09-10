'use client';

import React from 'react';
import { useSearchParams } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';
import { usd, REC_TYPE_LABEL, REC_STATUS } from '@/lib/format';
import { Card, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Rec = {
  id: string; asin: string; type: string; title: string | null; rationale: string | null;
  current_value: number | null; proposed_value: number | null; expected_impact: number | null;
  risk_score: number; required_approval_level: string; status: string; created_at: string;
  amazon_skus: { title: string } | null;
};

const STATUS_ORDER = ['pending_approval', 'draft', 'approved', 'executed', 'rejected', 'rolled_back'];

export default function RecommendationsList() {
  const params = useSearchParams();
  const [recs, setRecs] = React.useState<Rec[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState<string | null>(null);
  const [status, setStatus] = React.useState<string>('all');
  const [type, setType] = React.useState<string>('all');
  const [asin, setAsin] = React.useState(params.get('asin') ?? '');

  const load = React.useCallback(async () => {
    const { data, error: e } = await supabase
      .from('recommendations')
      .select('*, amazon_skus(title)')
      .order('created_at', { ascending: false });
    if (e) setError(e.message);
    else setRecs((data ?? []) as Rec[]);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on mount
    void load();
  }, [load]);

  async function transition(id: string, next: string) {
    setBusy(id);
    const patch: Record<string, unknown> = { status: next };
    if (next === 'approved') patch.approved_at = new Date().toISOString();
    if (next === 'executed') patch.executed_at = new Date().toISOString();
    const { error: e } = await supabase.from('recommendations').update(patch).eq('id', id);
    setBusy(null);
    if (e) setError(e.message); else load();
  }

  const counts = recs.reduce<Record<string, number>>((m, r) => ((m[r.status] = (m[r.status] ?? 0) + 1), m), {});

  const list = recs
    .filter((r) => status === 'all' || r.status === status)
    .filter((r) => type === 'all' || r.type === type)
    .filter((r) => !asin || r.asin.toLowerCase().includes(asin.toLowerCase()))
    .sort((a, b) => STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status)
      || Number(b.expected_impact ?? 0) - Number(a.expected_impact ?? 0));

  if (loading) return <Spinner />;
  if (error) return <ErrorBox message={error} />;

  return (
    <>
      {/* status tabs */}
      <div className="flex flex-wrap gap-2 mb-4">
        <Tab active={status === 'all'} onClick={() => setStatus('all')}>Tất cả <Count n={recs.length} /></Tab>
        {STATUS_ORDER.map((s) => (
          <Tab key={s} active={status === s} onClick={() => setStatus(s)}>
            {REC_STATUS[s].label} <Count n={counts[s] ?? 0} />
          </Tab>
        ))}
      </div>

      <div className="flex flex-wrap gap-2 mb-4">
        <select value={type} onChange={(e) => setType(e.target.value)} className={`${input} w-48`}>
          <option value="all">Mọi loại gợi ý</option>
          {Object.entries(REC_TYPE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <input value={asin} onChange={(e) => setAsin(e.target.value)} placeholder="Lọc theo ASIN" className={`${input} w-44 font-mono`} />
        {(asin || type !== 'all' || status !== 'all') && (
          <button className={btn.secondary} onClick={() => { setAsin(''); setType('all'); setStatus('all'); }}>Xóa bộ lọc</button>
        )}
      </div>

      {list.length === 0 ? (
        <Card><EmptyState title="Không có gợi ý phù hợp" description="Thử đổi bộ lọc hoặc chờ pipeline sinh gợi ý mới." /></Card>
      ) : (
        <div className="space-y-3">
          {list.map((r) => {
            const st = REC_STATUS[r.status] ?? { label: r.status, cls: 'bg-gray-100 text-gray-700' };
            const risk = Number(r.risk_score);
            const isBusy = busy === r.id;
            return (
              <Card key={r.id} className="p-5">
                <div className="flex flex-col md:flex-row md:items-start gap-4">
                  <div className="flex-1 min-w-0">
                    <div className="flex flex-wrap items-center gap-2 mb-1.5">
                      <Badge className="bg-indigo-50 text-indigo-700 ring-indigo-600/20">{REC_TYPE_LABEL[r.type] ?? r.type}</Badge>
                      <span className={`text-xs px-2 py-0.5 rounded-md font-medium ${st.cls}`}>{st.label}</span>
                      <Badge className="bg-gray-50 text-gray-600 ring-gray-500/20">Cấp duyệt {r.required_approval_level}</Badge>
                      <span className="text-xs text-gray-400">{new Date(r.created_at).toLocaleDateString('vi-VN')}</span>
                    </div>
                    <h3 className="text-base font-semibold text-gray-900">{r.title ?? '(không có tiêu đề)'}</h3>
                    <p className="text-sm text-gray-500 font-mono">{r.asin}<span className="font-sans">{r.amazon_skus?.title ? ` · ${r.amazon_skus.title}` : ''}</span></p>
                    {r.rationale && <p className="mt-2 text-sm text-gray-700 leading-relaxed">{r.rationale}</p>}
                  </div>

                  <dl className="grid grid-cols-4 md:grid-cols-1 gap-3 md:w-40 text-sm md:text-right shrink-0">
                    <Metric label="Hiện tại" value={r.current_value != null ? fmtVal(r.type, r.current_value) : '—'} />
                    <Metric label="Đề xuất" value={r.proposed_value != null ? fmtVal(r.type, r.proposed_value) : '—'} strong />
                    <Metric label="Tác động / tháng" value={r.expected_impact != null ? `+${usd(r.expected_impact, 0)}` : '—'} cls="text-emerald-700" />
                    <Metric label="Rủi ro" value={risk.toFixed(0)} cls={risk >= 50 ? 'text-orange-600' : 'text-emerald-600'} />
                  </dl>
                </div>

                <div className="mt-4 pt-4 border-t border-gray-100 flex flex-wrap gap-2">
                  {r.status === 'draft' && <button className={btn.primary} disabled={isBusy} onClick={() => transition(r.id, 'pending_approval')}>Gửi duyệt</button>}
                  {r.status === 'pending_approval' && (<>
                    <button className={btn.success} disabled={isBusy} onClick={() => transition(r.id, 'approved')}>✓ Phê duyệt</button>
                    <button className={btn.danger} disabled={isBusy} onClick={() => transition(r.id, 'rejected')}>Từ chối</button>
                  </>)}
                  {r.status === 'approved' && <button className={btn.success} disabled={isBusy} onClick={() => transition(r.id, 'executed')}>Đánh dấu đã thực thi</button>}
                  {r.status === 'executed' && <button className={btn.secondary} disabled={isBusy} onClick={() => transition(r.id, 'rolled_back')}>Hoàn tác</button>}
                  {(r.status === 'rejected' || r.status === 'rolled_back') && <button className={btn.secondary} disabled={isBusy} onClick={() => transition(r.id, 'draft')}>Mở lại</button>}
                </div>
              </Card>
            );
          })}
        </div>
      )}
    </>
  );
}

function fmtVal(type: string, v: number) {
  return type === 'price_adjust' ? usd(v) : `${Number(v).toLocaleString('vi-VN')} đv`;
}
function Metric({ label, value, strong, cls = '' }: { label: string; value: string; strong?: boolean; cls?: string }) {
  return (
    <div>
      <dt className="text-xs text-gray-500">{label}</dt>
      <dd className={`tabular-nums ${strong ? 'font-semibold text-gray-900' : 'text-gray-800'} ${cls}`}>{value}</dd>
    </div>
  );
}
function Tab({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button onClick={onClick}
      className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm font-medium transition ${
        active ? 'bg-slate-900 text-white' : 'bg-white text-gray-700 border border-gray-200 hover:bg-gray-50'}`}>
      {children}
    </button>
  );
}
function Count({ n }: { n: number }) {
  return <span className="text-xs opacity-70">{n}</span>;
}
