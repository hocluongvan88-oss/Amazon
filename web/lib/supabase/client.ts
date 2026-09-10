/**
 * Supabase Client for Vexim Amazon Managed Operations dashboard
 *
 * Usage:
 *   import { supabase } from '@/lib/supabase/client';
 *   const { data, error } = await supabase.from('amazon_skus').select('*');
 *
 * Environment variables required:
 *   NEXT_PUBLIC_SUPABASE_URL=https://<your-project>.supabase.co
 *   NEXT_PUBLIC_SUPABASE_ANON_KEY=<your-anon-key>
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

export const isSupabaseConfigured = Boolean(url && key);

let client: SupabaseClient | null = null;

function getClient(): SupabaseClient {
  if (!client) {
    if (!url || !key) {
      throw new Error(
        'Thiếu biến môi trường Supabase. Hãy thêm NEXT_PUBLIC_SUPABASE_URL và NEXT_PUBLIC_SUPABASE_ANON_KEY (trong .env.local khi chạy local, hoặc Vercel → Settings → Environment Variables khi deploy).'
      );
    }
    client = createClient(url, key);
  }
  return client;
}

/**
 * Lazily-initialised client. The real client is only created on first use,
 * so importing this module during `next build` (prerender) does not throw
 * when the env vars are not available.
 */
export const supabase: SupabaseClient = new Proxy({} as SupabaseClient, {
  get(_target, prop, receiver) {
    const real = getClient();
    const value = Reflect.get(real, prop, receiver);
    return typeof value === 'function' ? value.bind(real) : value;
  },
});
