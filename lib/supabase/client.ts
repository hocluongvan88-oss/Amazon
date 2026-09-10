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

// To keep things simple and avoid SSR issues at build time, we read the
 * env vars here.  Vercel and Next.js expose prefixed vars on the client.
 const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
 const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

 if (!url || !key) {
   throw new Error(
     'Missing Supabase environment variables. Add NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY to your .env.local'
   );
 }

 import { createClient } from '@supabase/supabase-js';

 export const supabase = createClient(url, key);