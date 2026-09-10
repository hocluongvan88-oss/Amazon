/**
 * Supabase client cho Server Components / Route Handlers / Server Actions.
 */
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';
import { SERVER_URL, ANON_KEY, cookieName } from './env';

export async function createClient() {
  const cookieStore = await cookies();
  return createServerClient(SERVER_URL!, ANON_KEY!, {
    cookieOptions: { name: cookieName() },
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (list) => {
        try {
          list.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // gọi từ Server Component: không set được cookie, proxy.ts sẽ lo refresh
        }
      },
    },
  });
}
