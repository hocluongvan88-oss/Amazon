/**
 * URL Supabase dùng ở server (proxy / route handlers) và tên cookie phiên.
 * SUPABASE_INTERNAL_URL là tuỳ chọn (dùng khi server cần gọi qua mạng nội bộ);
 * tên cookie luôn suy từ URL công khai để trình duyệt & server khớp nhau.
 */
export const PUBLIC_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
export const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
export const SERVER_URL = process.env.SUPABASE_INTERNAL_URL ?? PUBLIC_URL;

export function cookieName(): string | undefined {
  if (!PUBLIC_URL) return undefined;
  try {
    return `sb-${new URL(PUBLIC_URL).hostname.split('.')[0]}-auth-token`;
  } catch {
    return undefined;
  }
}
