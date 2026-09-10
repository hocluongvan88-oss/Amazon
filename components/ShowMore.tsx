'use client';

import React from 'react';
import { btn } from '@/components/ui';

/**
 * Phân trang client dạng component (không phải hook) → đặt được ở bất kỳ đâu trong JSX,
 * kể cả sau early‑return. Reset về trang đầu khi độ dài danh sách thay đổi.
 */
export function Paged<T>({ items, page, label = 'mục', children }: { items: T[]; page: number; label?: string; children: (visible: T[]) => React.ReactNode }) {
  const [n, setN] = React.useState(page);
  const [lastLen, setLastLen] = React.useState(items.length);
  if (items.length !== lastLen) { setLastLen(items.length); setN(page); }
  const visible = items.slice(0, n);
  return (
    <>
      {children(visible)}
      {items.length > page && (
        <div className="flex items-center justify-between px-5 py-3 border-t border-gray-100 text-xs text-gray-500">
          <span>Hiển thị {visible.length}/{items.length} {label}</span>
          {n < items.length && <button className={btn.secondary} onClick={() => setN((x) => x + page)}>Xem thêm {Math.min(page, items.length - n)}</button>}
        </div>
      )}
    </>
  );
}
