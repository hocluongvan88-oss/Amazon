'use client';

import React from 'react';
import { useSearchParams } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';
import { usd, REC_TYPE_LABEL, REC_STATUS } from '@/lib/format';
import { useTenant, ROLE_LABEL } from '@/lib/tenant';
import { Card, Badge, EmptyState, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Rec = {
  id: string; asin: string; type: string; title: string | null; rationale: string | null;
  current_value: number | null; proposed_value: number | null; expected_impact: number | null;
  risk_score: number; required_approval_level: string; status: string; created_at: string;
  submitted_at: string | null; approved_at: string | null; rejected_at: string | null; executed_at: string | null;
  rejection_reason: string | null; rollback_reason: string | null;
  amazon_skus: { title: string } | null;
};

const STATUS_ORDER = ['pending_approval', 'draft', 'approved', 'executed', 'rejected', 'rolled_back'];
const LEVEL_HINT: Record<string, string> = {
  L0: 'Tự động / xác nhận nhanh – Operator trở lên',
  L1: 'Operator hoặc Owner duyệt',
  L2: 'Chỉ Owner duyệt',
};

export default function RecommendationsList() {
  const params = useSearchParams();
  const { tenant, canWrite, canApprove } = useTenant();
  const [recs, setRecs] = React.useState<Rec[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState<string | null>(null);
  const [status, setStatus] = React.useState('all');
  const [type, setType] = React.useState('all');
  const [asin, setAsin] = React.useState(params.get('asin') ?? '');
  const [reasonFor, setReasonFor] = React.useState<{ id: string; kind: 'rejected' | 'rolled_back' } | null>(null);

  const load = React.useCallback(async () => {
    if (!tenant) return;
    const { data, error: e } = await supabase
      .from('recommendations')
      .select('*, amazon_skus(title)')
      .eq('tenant_id', tenant.id)
      .order('created_at', { ascending: false });
    if (e) setError(e.message); else { setError(null); setRecs((data ?? []) as Rec[]); }
    setLoading(false);
  }, [tenant]);

  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void load();
  }, [load]);

  async function transition(id: string, next: string, reason?: string) {
    setBusy(id);
    const patch: Record<string, unknown> = { status: next };
    if (next === 'rejected') patch.rejection_reason = reason;
    if (next === 'rolled_back') patch.rollback_reason = reason;
    const { error: e } = await supabase.from('recommendations').update(patch).eq('id', id);
    setBusy(null);
    if (e) setError(friendly(e.message)); else load();
  }

  const counts = recs.reduce<Record<string, number>>((m, r) => ((m[r.status] = (m[r.status] ?? 0) + 1), m), {});
  const list = recs
    .filter((r) => status === 'all' || r.status === status)
    .filter((r) => type === 'all' || r.type === type)
    .filter((r) => !asin || r.asin.toLowerCase().includes(asin.toLowerCase()))
    .sort((a, b) => STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status)
      || Number(b.expected_impact ?? 0) - Number(a.expected_impact ?? 0));

  if (loading) return <Spinner />;

  return (
    <>
      {error && <div className="mb-4"><ErrorBox message={error} /></div>}

      {tenant && (
        <p className="text-xs text-gray-500 mb-3">
          Bạn là <b>{ROLE_LABEL[tenant.role]}</b> của {tenant.name}
          {tenant.role === 'viewer' && ' – chỉ xem, không thao tác được.'}
          {tenant.role === 'operator' && ' – duyệt được cấp L0/L1; cấp L2 cần Owner.'}
          {tenant.role === 'owner' && ' – duyệt được mọi cấp.'}
        </p>
      )}

      <div className="flex flex-wrap gap-2 mb-4">
        <Tab active={status === 'all'} onClick={() => setStatus('all')}>Tất cả <Count n={recs.length} /></Tab>
        {STATUS_ORDER.map((s) => (
          <Tab key={s} active={status === s} onClick={() => setStatus(s)}>{REC_STATUS[s].label} <Count n={counts[s] ?? 0} /></Tab>
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
            const allowed = canApprove(r.required_approval_level);
            const lockMsg = !canWrite ? 'Vai trò Viewer không thao tác được' : !allowed ? `Cấp ${r.required_approval_level} cần Owner duyệt` : null;
            return (
              <Card key={r.id} className="p-5">
                <div className="flex flex-col md:flex-row md:items-start gap-4">
                  <div className="flex-1 min-w-0">
                    <div className="flex flex-wrap items-center gap-2 mb-1.5">
                      <Badge className="bg-indigo-50 text-indigo-700 ring-indigo-600/20">{REC_TYPE_LABEL[r.type] ?? r.type}</Badge>
                      <span className={`text-xs px-2 py-0.5 rounded-md font-medium ${st.cls}`}>{st.label}</span>
                      <Badge className="bg-gray-50 text-gray-600 ring-gray-500/20" >
                        <span title={LEVEL_HINT[r.required_approval_level]}>Cấp duyệt {r.required_approval_level}</span>
                      </Badge>
                      <span className="text-xs text-gray-400">{new Date(r.created_at).toLocaleDateString('vi-VN')}</span>
                    </div>
                    <h3 className="text-base font-semibold text-gray-900">{r.title ?? '(không có tiêu đề)'}</h3>
                    <p className="text-sm text-gray-500 font-mono">{r.asin}<span className="font-sans">{r.amazon_skus?.title ? ` · ${r.amazon_skus.title}` : ''}</span></p>
                    {r.rationale && <p className="mt-2 text-sm text-gray-700 leading-relaxed">{r.rationale}</p>}
                    <Timeline r={r} />
                  </div>

                  <dl className="grid grid-cols-4 md:grid-cols-1 gap-3 md:w-40 text-sm md:text-right shrink-0">
                    <Metric label="Hiện tại" value={r.current_value != null ? fmtVal(r.type, r.current_value) : '—'} />
                    <Metric label="Đề xuất" value={r.proposed_value != null ? fmtVal(r.type, r.proposed_value) : '—'} strong />
                    <Metric label="Tác động / tháng" value={r.expected_impact != null ? `+${usd(r.expected_impact, 0)}` : '—'} cls="text-emerald-700" />
                    <Metric label="Rủi ro" value={risk.toFixed(0)} cls={risk >= 50 ? 'text-orange-600' : 'text-emerald-600'} />
                  </dl>
                </div>

                {canWrite && (
                  <div className="mt-4 pt-4 border-t border-gray-100 flex flex-wrap items-center gap-2">
                    {r.status === 'draft' && <button className={btn.primary} disabled={isBusy} onClick={() => transition(r.id, 'pending_approval')}>Gửi duyệt</button>}
                    {r.status === 'pending_approval' && (<>
                      <button className={btn.success} disabled={isBusy || !allowed} onClick={() => transition(r.id, 'approved')}>✓ Phê duyệt</button>
                      <button className={btn.danger} disabled={isBusy || !allowed} onClick={() => setReasonFor({ id: r.id, kind: 'rejected' })}>Từ chối…</button>
                    </>)}
                    {r.status === 'approved' && (<>
                      <button className={btn.success} disabled={isBusy || !allowed} onClick={() => transition(r.id, 'executed')}>Đánh dấu đã thực thi</button>
                      <button className={btn.secondary} disabled={isBusy || !allowed} onClick={() => setReasonFor({ id: r.id, kind: 'rejected' })}>Huỷ duyệt…</button>
                    </>)}
                    {r.status === 'executed' && <button className={btn.secondary} disabled={isBusy || !allowed} onClick={() => setReasonFor({ id: r.id, kind: 'rolled_back' })}>Hoàn tác…</button>}
                    {(r.status === 'rejected' || r.status === 'rolled_back') && <button className={btn.secondary} disabled={isBusy} onClick={() => transition(r.id, 'draft')}>Mở lại</button>}
                    {lockMsg && r.status !== 'draft' && r.status !== 'rejected' && r.status !== 'rolled_back' && (
                      <span className="text-xs text-gray-500">🔒 {lockMsg}</span>
                    )}
                  </div>
                )}
              </Card>
            );
          })}
        </div>
      )}

      {reasonFor && (
        <ReasonDialog
          title={reasonFor.kind === 'rejected' ? 'Lý do từ chối' : 'Lý do hoàn tác'}
          onCancel={() => setReasonFor(null)}
          onSubmit={(reason) => { const { id, kind } = reasonFor; setReasonFor(null); transition(id, kind, reason); }}
        />
      )}
    </>
  );
}

function friendly(msg: string) {
  if (msg.includes('không đủ quyền')) return msg;
  if (msg.includes('không hợp lệ')) return msg;
  if (msg.includes('row-level security')) return 'Bạn không có quyền thực hiện thao tác này trong brand hiện tại.';
  return msg;
}

function Timeline({ r }: { r: Rec }) {
  const items: { label: string; at: string | null; note?: string | null }[] = [
    { label: 'Gửi duyệt', at: r.submitted_at },
    { label: 'Phê duyệt', at: r.approved_at },
    { label: 'Từ chối', at: r.rejected_at, note: r.rejection_reason },
    { label: 'Thực thi', at: r.executed_at },
  ].filter((i) => i.at);
  if (!items.length && !r.rollback_reason) return null;
  return (
    <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-500">
      {items.map((i) => (
        <li key={i.label}>{i.label}: {new Date(i.at!).toLocaleString('vi-VN')}{i.note ? <span className="text-red-600"> – “{i.note}”</span> : null}</li>
      ))}
      {r.rollback_reason && <li className="text-orange-700">Hoàn tác – “{r.rollback_reason}”</li>}
    </ul>
  );
}

function ReasonDialog({ title, onCancel, onSubmit }: { title: string; onCancel: () => void; onSubmit: (reason: string) => void }) {
  const [v, setV] = React.useState('');
  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4" onClick={onCancel}>
      <div className="bg-white rounded-xl shadow-xl w-full max-w-md p-5" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-base font-semibold text-gray-900">{title}</h3>
        <p className="text-sm text-gray-500 mt-1">Lý do sẽ được lưu vào nhật ký và hiển thị trên gợi ý.</p>
        <textarea autoFocus value={v} onChange={(e) => setV(e.target.value)} rows={3} className={`${input} mt-3`} placeholder="Ví dụ: đối thủ vừa giảm giá, chờ thêm 1 tuần dữ liệu…" />
        <div className="mt-4 flex justify-end gap-2">
          <button className={btn.secondary} onClick={onCancel}>Huỷ</button>
          <button className={btn.danger} disabled={v.trim().length < 3} onClick={() => onSubmit(v.trim())}>Xác nhận</button>
        </div>
      </div>
    </div>
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
    <button onClick={onClick} className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm font-medium transition ${
      active ? 'bg-slate-900 text-white' : 'bg-white text-gray-700 border border-gray-200 hover:bg-gray-50'}`}>{children}</button>
  );
}
function Count({ n }: { n: number }) { return <span className="text-xs opacity-70">{n}</span>; }
