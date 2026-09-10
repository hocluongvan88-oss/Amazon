'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import React from 'react';

const NAV = [
  { href: '/', label: 'Tổng quan', icon: '▦' },
  { href: '/recommendations', label: 'Gợi ý & phê duyệt', icon: '✓' },
  { href: '/exceptions', label: 'Ngoại lệ', icon: '!' },
  { href: '/add-sku', label: 'Thêm SKU', icon: '+' },
];

export default function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  return (
    <div className="min-h-screen flex">
      <aside className="hidden md:flex w-60 shrink-0 flex-col bg-slate-900 text-slate-200">
        <div className="px-5 py-5 border-b border-slate-800">
          <Link href="/" className="block">
            <p className="text-lg font-bold text-white tracking-tight">Vexim Ops</p>
            <p className="text-xs text-slate-400">Amazon Managed Operations</p>
          </Link>
        </div>
        <nav className="flex-1 px-3 py-4 space-y-1">
          {NAV.map((n) => {
            const active = n.href === '/' ? pathname === '/' : pathname.startsWith(n.href);
            return (
              <Link
                key={n.href}
                href={n.href}
                className={`flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition ${
                  active ? 'bg-indigo-600 text-white' : 'text-slate-300 hover:bg-slate-800 hover:text-white'
                }`}
              >
                <span className="w-5 text-center text-xs opacity-80">{n.icon}</span>
                {n.label}
              </Link>
            );
          })}
        </nav>
        <div className="px-5 py-4 border-t border-slate-800 text-xs text-slate-500">
          Pilot · Marketplace US
        </div>
      </aside>

      <div className="flex-1 flex flex-col min-w-0">
        <header className="md:hidden bg-slate-900 text-white px-4 py-3 flex items-center justify-between">
          <Link href="/" className="font-bold">Vexim Ops</Link>
          <nav className="flex gap-3 text-sm">
            {NAV.map((n) => (
              <Link key={n.href} href={n.href} className={pathname === n.href ? 'text-white' : 'text-slate-400'}>
                {n.label}
              </Link>
            ))}
          </nav>
        </header>
        <main className="flex-1 px-4 sm:px-6 lg:px-8 py-6 max-w-[1400px] w-full mx-auto">{children}</main>
      </div>
    </div>
  );
}
