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

import { createClient } from '@supabase/supabase-js';

// To keep things simple and avoid SSR issues at build time, we read the
// env vars here. Vercel and Next.js expose prefixed vars on the client.
const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'https://placeholder.supabase.co';
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'placeholder-anon-key';

export const supabase = createClient(url, key);
