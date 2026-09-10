import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { SERVER_URL, ANON_KEY, cookieName } from '@/lib/supabase/env';

const PUBLIC_PATHS = ['/login', '/auth'];

export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });

  const url = SERVER_URL;
  const key = ANON_KEY;
  if (!url || !key) return response; // chưa cấu hình → để app tự báo lỗi

  const supabase = createServerClient(url, key, {
    cookieOptions: { name: cookieName() },
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  // Quan trọng: getUser() (không phải getSession) để refresh token & xác thực với server
  const { data: { user } } = await supabase.auth.getUser();

  const { pathname } = request.nextUrl;
  const isPublic = PUBLIC_PATHS.some((p) => pathname.startsWith(p));

  if (!user && !isPublic) {
    const to = request.nextUrl.clone();
    to.pathname = '/login';
    to.searchParams.set('next', pathname);
    return NextResponse.redirect(to);
  }
  if (user && pathname === '/login') {
    const to = request.nextUrl.clone();
    to.pathname = '/';
    to.search = '';
    return NextResponse.redirect(to);
  }
  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)'],
};
