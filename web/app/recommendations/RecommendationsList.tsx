'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';

type Rec = {
  id: string;
  asin: string;
  type: string;
  title: string | null;
  rationale: string | null;
  current_value: number | null;
  proposed_value: number | null;
  expected_impact: number | null;
  risk_score: number;
  required_approval_level: string;
  status: string;
  created_at: string;
  amazon_skus: { title: string } | null;
};

const TYPE_LABEL: Record<string, string> = {
  price_adjust: 'Điều chỉnh giá',
  replenish: 'Nhập hàng',
  review_response: 'Phản hồi review',
  inventory_transfer: 'Chuyển kho',
};

const STATUS: Record<string, { label: string; cls: string }> = {
  draft: { label: 'Nháp', cls: 'bg-gray-100 text-gray-700' },
  pending_approval: { label: 'Chờ duyệt', cls: 'bg-yellow-100 text-yellow-800' },
  approved: { label: 'Đã duyệt', cls: 'bg-blue-100 text-blue-800' },
  rejected: { label: 'Từ chối', cls: 'bg-red-100 text-red-800' },
  executed: { label: 'Đã thực thi', cls: 'bg-green-100 text-green-800' },
  rolled_back: { label: 'Đã hoàn tác', cls: 'bg-orange-100 text-orange-800' },
};

export default function RecommendationsList() {
  const [recs, setRecs] = React.useState<Rec[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [busy, setBusy] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    const { data, error: fetchError } = await supabase
      .from('recommendations')
      .select('*, amazon_skus(title)')
      .order('created_at', { ascending: false });
    if (fetchError) setError(fetchError.message);
    else setRecs((data ?? []) as Rec[]);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    load();
  }, [load]);

  async function setStatus(id: string, status: string) {
    setBusy(id);
    const patch: Record<string, unknown> = { status };
    if (status === 'approved') patch.approved_at = new Date().toISOString();
    if (status === 'executed') patch.executed_at = new Date().toISOString();
    const { error: updError } = await supabase.from('recommendations').update(patch).eq('id', id);
    setBusy(null);
    if (updError) setError(updError.message);
    else load();
  }

  if (loading) return <p>Đang tải dữ liệu…</p>;
  if (error) return <p className="text-red-600">Lỗi: {error}</p>;
  if (recs.length === 0)
    return (
      <p className="text-gray-600">
        Chưa có gợi ý nào. Sau khi chạy pipeline sẽ hiển thị các gợi ý về giá, tồn kho và review.
      </p>
    );

  return (
    <div className="space-y-4">
      {recs.map((r) => {
        const st = STATUS[r.status] ?? { label: r.status, cls: 'bg-gray-100' };
        return (
          <article key={r.id} className="bg-white rounded-lg shadow-sm border border-gray-200 p-5">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div className="flex flex-wrap items-center gap-2 mb-1">
                  <span className="text-xs font-semibold uppercase tracking-wide text-indigo-600">
                    {TYPE_LABEL[r.type] ?? r.type}
                  </span>
                  <span className={`text-xs px-2 py-0.5 rounded-full ${st.cls}`}>{st.label}</span>
                  <span className="text-xs px-2 py-0.5 rounded-full bg-gray-100 text-gray-600">
                    Duyệt: {r.required_approval_level}
                  </span>
                </div>
                <h2 className="text-lg font-semibold text-gray-900">{r.title ?? '(không có tiêu đề)'}</h2>
                <p className="text-sm text-gray-500">
                  {r.asin}
                  {r.amazon_skus?.title ? ` · ${r.amazon_skus.title}` : ''}
                </p>
              </div>
              <div className="text-right text-sm">
                <p className="text-gray-500">Rủi ro</p>
                <p className={`text-2xl font-bold ${r.risk_score >= 50 ? 'text-orange-600' : 'text-green-600'}`}>
                  {Number(r.risk_score).toFixed(0)}
                </p>
              </div>
            </div>

            {r.rationale && <p className="mt-3 text-sm text-gray-700">{r.rationale}</p>}

            <dl className="mt-3 grid grid-cols-3 gap-4 text-sm">
              <div>
                <dt className="text-gray-500">Hiện tại</dt>
                <dd className="font-medium">{r.current_value ?? '—'}</dd>
              </div>
              <div>
                <dt className="text-gray-500">Đề xuất</dt>
                <dd className="font-medium">{r.proposed_value ?? '—'}</dd>
              </div>
              <div>
                <dt className="text-gray-500">Tác động ước tính</dt>
                <dd className="font-medium text-green-700">
                  {r.expected_impact != null ? `$${Number(r.expected_impact).toFixed(0)}/tháng` : '—'}
                </dd>
              </div>
            </dl>

            <div className="mt-4 flex flex-wrap gap-2">
              {r.status === 'draft' && (
                <Btn onClick={() => setStatus(r.id, 'pending_approval')} disabled={busy === r.id}>
                  Gửi duyệt
                </Btn>
              )}
              {r.status === 'pending_approval' && (
                <>
                  <Btn onClick={() => setStatus(r.id, 'approved')} disabled={busy === r.id} color="green">
                    Phê duyệt
                  </Btn>
                  <Btn onClick={() => setStatus(r.id, 'rejected')} disabled={busy === r.id} color="red">
                    Từ chối
                  </Btn>
                </>
              )}
              {r.status === 'approved' && (
                <Btn onClick={() => setStatus(r.id, 'executed')} disabled={busy === r.id} color="green">
                  Đánh dấu đã thực thi
                </Btn>
              )}
              {r.status === 'executed' && (
                <Btn onClick={() => setStatus(r.id, 'rolled_back')} disabled={busy === r.id} color="red">
                  Hoàn tác
                </Btn>
              )}
            </div>
          </article>
        );
      })}
    </div>
  );
}

function Btn({
  children,
  onClick,
  disabled,
  color = 'indigo',
}: {
  children: React.ReactNode;
  onClick: () => void;
  disabled?: boolean;
  color?: 'indigo' | 'green' | 'red';
}) {
  const cls = {
    indigo: 'bg-indigo-600 hover:bg-indigo-700',
    green: 'bg-green-600 hover:bg-green-700',
    red: 'bg-red-600 hover:bg-red-700',
  }[color];
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`px-3 py-1.5 text-sm font-medium text-white rounded-md transition disabled:opacity-60 ${cls}`}
    >
      {children}
    </button>
  );
}
