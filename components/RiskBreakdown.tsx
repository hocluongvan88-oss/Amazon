'use client';

import React from 'react';

export type RiskComponent = { score: number | null; weight: number; reason?: string | null; [k: string]: unknown };
export type RiskComponents = {
  inventory?: RiskComponent; margin?: RiskComponent; velocity?: RiskComponent; volatility?: RiskComponent;
  confidence?: number; coverage_days?: number;
} | null;

export const COMP_LABEL: Record<string, string> = { inventory: 'Tồn kho', margin: 'Biên lợi nhuận', velocity: 'Tốc độ bán', volatility: 'Biến động giá' };
const ORDER = ['inventory', 'margin', 'velocity', 'volatility'] as const;

export function riskBar(score: number) { return score >= 70 ? 'bg-red-500' : score >= 40 ? 'bg-amber-500' : 'bg-emerald-500'; }

/** Phân rã 4 thành phần điểm rủi ro; dùng ở SkuDetail (full) và popover Dashboard (compact). */
export default function RiskBreakdown({ c, total, compact = false }: { c: RiskComponents; total: number; compact?: boolean }) {
  if (!c) return <p className="text-xs text-gray-500">Chưa tính điểm rủi ro (chạy rule hoặc chờ 03:30 UTC).</p>;
  const conf = c.confidence != null ? Math.round(c.confidence * 100) : null;
  return (
    <div className={compact ? 'text-xs space-y-1.5' : 'text-sm space-y-2.5'}>
      {ORDER.map((k) => {
        const x = c[k]; if (!x) return null;
        const s = x.score == null ? null : Number(x.score);
        return (
          <div key={k}>
            <div className="flex items-center justify-between gap-2">
              <span className="text-gray-700">{COMP_LABEL[k]} <span className="text-gray-400">×{Number(x.weight).toFixed(2)}</span></span>
              <span className={`tabular-nums font-medium ${s == null ? 'text-gray-400' : ''}`}>{s == null ? 'n/a' : `${Math.round(s)}`}</span>
            </div>
            <div className="h-1.5 rounded bg-gray-100 mt-0.5"><div className={`h-1.5 rounded ${s == null ? 'bg-gray-300' : riskBar(s)}`} style={{ width: `${s ?? 0}%` }} /></div>
            {x.reason && !compact && <p className="text-xs text-gray-500 mt-0.5">{x.reason}</p>}
            {x.reason && compact && <p className="text-[11px] text-gray-500 truncate">{x.reason}</p>}
          </div>
        );
      })}
      <p className="text-xs text-gray-500 pt-1 border-t border-gray-100">
        Tổng <b className="text-gray-800">{Math.round(total)}</b>/100 · độ tin cậy {conf != null ? `${conf}%` : '—'}{c.coverage_days != null && ` · ${c.coverage_days} ngày dữ liệu`}
        {conf != null && conf < 60 && <span className="text-amber-700"> · thiếu dữ liệu, trọng số đã chuẩn hoá lại</span>}
      </p>
    </div>
  );
}
