'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import React from 'react';
import { useTenant, ROLE_LABEL } from '@/lib/tenant';
import { Card, btn } from '@/components/ui';

const NAV = [
  { href: '/', label: 'Tổng quan', icon: '▦' },
  { href: '/recommendations', label: 'Gợi ý & phê duyệt', icon: '✓' },
  { href: '/exceptions', label: 'Ngoại lệ', icon: '!' },
  { href: '/profit-bridge', label: 'Profit bridge', icon: '⇅' },
  { href: '/inventory', label: 'Tồn kho', icon: '▤' },
  { href: '/reviews', label: 'Đánh giá / VOC', icon: '★' },
  { href: '/add-sku', label: 'Thêm SKU', icon: '+', write: true },
  { href: '/import', label: 'Nhập dữ liệu', icon: '⇪', write: true },
  { href: '/actions', label: 'Lệnh thực thi', icon: '⚡' },
  { href: '/audit', label: 'Nhật ký', icon: '≡' },
  { href: '/settings/policy', label: 'Chính sách', icon: '§' },
  { href: '/settings/members', label: 'Thành viên', icon: '⚙', owner: true },
];

export default function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const { user, tenant, tenants, setTenantId, loading, canWrite } = useTenant();
  const isOwner = tenant?.role === 'owner';
  const nav = NAV.filter((n) => (!n.write || canWrite) && (!n.owner || isOwner));

  return (
    <div className="min-h-screen flex">
      <aside className="hidden md:flex w-60 shrink-0 flex-col bg-slate-900 text-slate-200">
        <div className="px-5 py-5 border-b border-slate-800">
          <Link href="/" className="block">
            <p className="text-lg font-bold text-white tracking-tight">Vexim Ops</p>
            <p className="text-xs text-slate-400">Amazon Managed Operations</p>
          </Link>
        </div>

        {/* Brand switcher */}
        <div className="px-3 pt-4">
          <label className="block text-[11px] uppercase tracking-wide text-slate-500 px-2 mb-1">Brand</label>
          {tenants.length > 1 ? (
            <select value={tenant?.id ?? ''} onChange={(e) => setTenantId(e.target.value)}
              className="w-full bg-slate-800 border border-slate-700 text-sm rounded-lg px-2 py-1.5 text-white">
              {tenants.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          ) : (
            <p className="px-2 text-sm font-medium text-white">{tenant?.name ?? (loading ? '…' : 'Chưa có brand')}</p>
          )}
          {tenant && <p className="px-2 mt-1 text-xs text-slate-400">Vai trò: {ROLE_LABEL[tenant.role]} · {tenant.marketplace}</p>}
        </div>

        <nav className="flex-1 px-3 py-4 space-y-1">
          {nav.map((n) => {
            const active = n.href === '/' ? pathname === '/' : pathname.startsWith(n.href);
            return (
              <Link key={n.href} href={n.href}
                className={`flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition ${
                  active ? 'bg-indigo-600 text-white' : 'text-slate-300 hover:bg-slate-800 hover:text-white'}`}>
                <span className="w-5 text-center text-xs opacity-80">{n.icon}</span>{n.label}
              </Link>
            );
          })}
        </nav>

        <div className="px-4 py-4 border-t border-slate-800">
          <p className="text-xs text-slate-400 truncate" title={user?.email}>{user?.email}</p>
          <form action="/auth/signout" method="post">
            <button className="mt-2 text-xs text-slate-300 hover:text-white underline">Đăng xuất</button>
          </form>
        </div>
      </aside>

      <div className="flex-1 flex flex-col min-w-0">
        <header className="md:hidden bg-slate-900 text-white px-4 py-3 flex items-center justify-between gap-3">
          <Link href="/" className="font-bold shrink-0">Vexim Ops</Link>
          <nav className="flex gap-3 text-xs overflow-x-auto">
            {nav.map((n) => (
              <Link key={n.href} href={n.href} className={`whitespace-nowrap ${pathname === n.href ? 'text-white' : 'text-slate-400'}`}>{n.label}</Link>
            ))}
          </nav>
        </header>
        <main className="flex-1 px-4 sm:px-6 lg:px-8 py-6 max-w-[1400px] w-full mx-auto">
          {!loading && user && tenants.length === 0 ? <NoTenant email={user.email} /> : children}
        </main>
      </div>
    </div>
  );
}

function NoTenant({ email }: { email: string }) {
  return (
    <Card className="max-w-xl mx-auto mt-10 p-8 text-center">
      <h1 className="text-xl font-bold text-gray-900">Tài khoản chưa thuộc brand nào</h1>
      <p className="mt-2 text-sm text-gray-600">
        Bạn đã đăng nhập bằng <b>{email}</b>, nhưng chưa được thêm vào brand nào. Hãy nhờ owner của brand thêm bạn
        ở mục <i>Thành viên</i>, hoặc nếu bạn là người thiết lập đầu tiên, chạy câu lệnh cuối file
        <code className="mx-1 px-1 bg-gray-100 rounded">supabase/004_tenancy_auth.sql</code> với email của bạn.
      </p>
      <form action="/auth/signout" method="post" className="mt-6">
        <button className={btn.secondary}>Đăng xuất</button>
      </form>
    </Card>
  );
}
