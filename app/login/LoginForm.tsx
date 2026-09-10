'use client';

import React from 'react';
import { useSearchParams } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';
import { btn, input } from '@/components/ui';

export default function LoginForm() {
  const params = useSearchParams();
  const next = params.get('next') ?? '/';
  const linkError = params.get('error') === 'link';

  const [mode, setMode] = React.useState<'magic' | 'password'>('magic');
  const [email, setEmail] = React.useState('');
  const [password, setPassword] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [sent, setSent] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    if (mode === 'magic') {
      const { error: err } = await supabase.auth.signInWithOtp({
        email,
        options: { emailRedirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}` },
      });
      if (err) setError(err.message); else setSent(true);
    } else {
      const { error: err } = await supabase.auth.signInWithPassword({ email, password });
      if (err) setError(err.message === 'Invalid login credentials' ? 'Email hoặc mật khẩu không đúng.' : err.message);
      else window.location.assign(next);
    }
    setBusy(false);
  }

  return (
    <div className="w-full max-w-sm">
      <div className="lg:hidden mb-6">
        <p className="text-xl font-bold text-gray-900">Vexim Ops</p>
      </div>
      <h1 className="text-2xl font-bold text-gray-900">Đăng nhập</h1>
      <p className="text-sm text-gray-600 mt-1 mb-6">Chỉ tài khoản được mời vào một brand mới xem được dữ liệu.</p>

      {linkError && <Alert tone="red">Liên kết đăng nhập không hợp lệ hoặc đã hết hạn. Hãy yêu cầu liên kết mới.</Alert>}

      {sent ? (
        <Alert tone="green">
          Đã gửi liên kết đăng nhập tới <b>{email}</b>. Mở email và bấm vào liên kết (kiểm tra cả thư rác).
        </Alert>
      ) : (
        <form onSubmit={submit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Email</label>
            <input type="email" required autoFocus value={email} onChange={(e) => setEmail(e.target.value)} className={input} placeholder="ban@congty.com" />
          </div>
          {mode === 'password' && (
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Mật khẩu</label>
              <input type="password" required value={password} onChange={(e) => setPassword(e.target.value)} className={input} />
            </div>
          )}
          {error && <Alert tone="red">{error}</Alert>}
          <button type="submit" disabled={busy} className={`${btn.primary} w-full justify-center`}>
            {busy ? 'Đang xử lý…' : mode === 'magic' ? 'Gửi liên kết đăng nhập' : 'Đăng nhập'}
          </button>
          <button type="button" onClick={() => setMode(mode === 'magic' ? 'password' : 'magic')} className="w-full text-sm text-indigo-600 hover:underline">
            {mode === 'magic' ? 'Dùng mật khẩu thay vì liên kết email' : 'Dùng liên kết email (magic link)'}
          </button>
        </form>
      )}
    </div>
  );
}

function Alert({ tone, children }: { tone: 'red' | 'green'; children: React.ReactNode }) {
  const cls = tone === 'red' ? 'bg-red-50 border-red-200 text-red-700' : 'bg-emerald-50 border-emerald-200 text-emerald-800';
  return <div className={`rounded-lg border p-3 text-sm mb-4 ${cls}`}>{children}</div>;
}
