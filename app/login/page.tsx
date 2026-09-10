import type { Metadata } from 'next';
import { Suspense } from 'react';
import LoginForm from './LoginForm';

export const metadata: Metadata = { title: 'Đăng nhập' };

export default function LoginPage() {
  return (
    <div className="min-h-screen grid lg:grid-cols-2">
      <div className="hidden lg:flex flex-col justify-between bg-slate-900 text-slate-200 p-10">
        <div>
          <p className="text-2xl font-bold text-white">Vexim Ops</p>
          <p className="text-sm text-slate-400">Amazon Managed Operations</p>
        </div>
        <div className="space-y-4 max-w-md">
          <p className="text-xl font-semibold text-white leading-snug">
            Lợi nhuận góp phần, tồn kho và phê duyệt – trong một bàn điều khiển có kiểm soát của con người.
          </p>
          <ul className="text-sm text-slate-300 space-y-1.5">
            <li>• Phát hiện → chẩn đoán → đề xuất → duyệt → thực thi → đo lường</li>
            <li>• Cấp duyệt L0–L2, mọi hành động đều được ghi nhật ký</li>
            <li>• Dữ liệu tách biệt theo từng brand</li>
          </ul>
        </div>
        <p className="text-xs text-slate-500">© {new Date().getFullYear()} Vexim</p>
      </div>
      <div className="flex items-center justify-center p-6 bg-gray-50">
        <Suspense>
          <LoginForm />
        </Suspense>
      </div>
    </div>
  );
}
