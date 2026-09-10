/**
 * Supabase client cho trình duyệt (client components).
 * Dùng @supabase/ssr để session được lưu trong cookie → server đọc được.
 */
import { createBrowserClient } from '@supabase/ssr';
import type { SupabaseClient } from '@supabase/supabase-js';

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

export const isSupabaseConfigured = Boolean(url && key);

let client: SupabaseClient | null = null;

function getClient(): SupabaseClient {
  if (!client) {
    if (!url || !key) {
      throw new Error(
        'Thiếu biến môi trường Supabase. Hãy thêm NEXT_PUBLIC_SUPABASE_URL và NEXT_PUBLIC_SUPABASE_ANON_KEY.'
      );
    }
    client = createBrowserClient(url, key);
  }
  return client;
}

/** Lazy proxy: không throw khi import lúc build. */
export const supabase: SupabaseClient = new Proxy({} as SupabaseClient, {
  get(_t, prop, receiver) {
    const real = getClient();
    const v = Reflect.get(real, prop, receiver);
    return typeof v === 'function' ? v.bind(real) : v;
  },
});
