export const usd = (n: number | null | undefined, digits = 2) =>
  n == null ? '—' : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: digits, minimumFractionDigits: digits }).format(Number(n));

export const num = (n: number | null | undefined, digits = 0) =>
  n == null ? '—' : new Intl.NumberFormat('vi-VN', { maximumFractionDigits: digits }).format(Number(n));

export const pct = (n: number | null | undefined, digits = 1) =>
  n == null ? '—' : `${Number(n).toFixed(digits)}%`;

export type RiskLevel = 'critical' | 'high' | 'medium' | 'low';

export function riskLevel(score: number): RiskLevel {
  if (score >= 80) return 'critical';
  if (score >= 60) return 'high';
  if (score >= 30) return 'medium';
  return 'low';
}

export const RISK_META: Record<RiskLevel, { label: string; cls: string; dot: string }> = {
  critical: { label: 'Nguy cấp', cls: 'bg-red-50 text-red-700 ring-red-600/20', dot: 'bg-red-500' },
  high: { label: 'Cao', cls: 'bg-orange-50 text-orange-700 ring-orange-600/20', dot: 'bg-orange-500' },
  medium: { label: 'Trung bình', cls: 'bg-yellow-50 text-yellow-800 ring-yellow-600/20', dot: 'bg-yellow-500' },
  low: { label: 'Ổn định', cls: 'bg-green-50 text-green-700 ring-green-600/20', dot: 'bg-green-500' },
};

export const REC_TYPE_LABEL: Record<string, string> = {
  price_adjust: 'Điều chỉnh giá',
  replenish: 'Nhập hàng',
  review_response: 'Phản hồi review',
  inventory_transfer: 'Chuyển kho',
};

export const REC_STATUS: Record<string, { label: string; cls: string }> = {
  draft: { label: 'Nháp', cls: 'bg-gray-100 text-gray-700' },
  pending_approval: { label: 'Chờ duyệt', cls: 'bg-yellow-100 text-yellow-800' },
  approved: { label: 'Đã duyệt', cls: 'bg-blue-100 text-blue-800' },
  rejected: { label: 'Từ chối', cls: 'bg-red-100 text-red-800' },
  executed: { label: 'Đã thực thi', cls: 'bg-green-100 text-green-800' },
  rolled_back: { label: 'Đã hoàn tác', cls: 'bg-orange-100 text-orange-800' },
};
