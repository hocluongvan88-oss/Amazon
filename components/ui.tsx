import React from 'react';

export function Card({ children, className = '', id }: { children: React.ReactNode; className?: string; id?: string }) {
  return <div id={id} className={`bg-white rounded-xl border border-gray-200 shadow-sm ${className}`}>{children}</div>;
}

export function CardHeader({ title, subtitle, action }: { title: string; subtitle?: string; action?: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4 px-5 py-4 border-b border-gray-100">
      <div>
        <h2 className="text-base font-semibold text-gray-900">{title}</h2>
        {subtitle && <p className="text-sm text-gray-500 mt-0.5">{subtitle}</p>}
      </div>
      {action}
    </div>
  );
}

export function Badge({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return (
    <span className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-xs font-medium ring-1 ring-inset ${className}`}>
      {children}
    </span>
  );
}

export function StatCard({
  label, value, hint, tone = 'default', icon,
}: {
  label: string; value: React.ReactNode; hint?: string;
  tone?: 'default' | 'green' | 'red' | 'amber' | 'blue'; icon?: React.ReactNode;
}) {
  const tones = {
    default: 'text-gray-900',
    green: 'text-emerald-600',
    red: 'text-red-600',
    amber: 'text-amber-600',
    blue: 'text-indigo-600',
  };
  return (
    <Card className="p-5">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium text-gray-500">{label}</p>
        {icon && <span className="text-gray-400">{icon}</span>}
      </div>
      <p className={`mt-2 text-2xl font-bold tracking-tight ${tones[tone]}`}>{value}</p>
      {hint && <p className="mt-1 text-xs text-gray-500">{hint}</p>}
    </Card>
  );
}

export function EmptyState({ title, description, action }: { title: string; description?: string; action?: React.ReactNode }) {
  return (
    <div className="text-center py-12 px-4">
      <p className="text-gray-900 font-medium">{title}</p>
      {description && <p className="text-sm text-gray-500 mt-1">{description}</p>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

export function Spinner({ label = 'Đang tải dữ liệu…' }: { label?: string }) {
  return (
    <div className="flex items-center gap-3 text-gray-500 py-12 justify-center">
      <span className="h-5 w-5 rounded-full border-2 border-gray-300 border-t-indigo-600 animate-spin" />
      <span className="text-sm">{label}</span>
    </div>
  );
}

export function ErrorBox({ message }: { message: string }) {
  return (
    <div className="rounded-lg bg-red-50 border border-red-200 p-4 text-sm text-red-700">
      <p className="font-medium">Không tải được dữ liệu</p>
      <p className="mt-1">{message}</p>
    </div>
  );
}

export const btn = {
  primary: 'inline-flex items-center gap-2 px-3.5 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-60',
  secondary: 'inline-flex items-center gap-2 px-3.5 py-2 text-sm font-medium rounded-lg bg-white text-gray-700 border border-gray-300 hover:bg-gray-50 transition disabled:opacity-60',
  success: 'inline-flex items-center gap-2 px-3.5 py-2 text-sm font-medium rounded-lg bg-emerald-600 text-white hover:bg-emerald-700 transition disabled:opacity-60',
  danger: 'inline-flex items-center gap-2 px-3.5 py-2 text-sm font-medium rounded-lg bg-red-600 text-white hover:bg-red-700 transition disabled:opacity-60',
  ghost: 'inline-flex items-center gap-1 px-2 py-1 text-sm font-medium rounded-md text-indigo-600 hover:bg-indigo-50 transition disabled:opacity-60',
};

export const input =
  'w-full px-3 py-2 text-sm border border-gray-300 rounded-lg bg-white focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500';
