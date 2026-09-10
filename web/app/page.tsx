/*
 * Dashboard page for Vexim Amazon Managed Operations
 * - Shows a list of ASINs with contribution profit & stockout risk
 * - Requires Supabase authentication (sign‑in with Google or email/password)
 * - Row‑level security enforced via the profiles / amazon_skus policies
 */

import { supabase } from '@/lib/supabase/client';

export async function metadata() {
  return {
    title: 'Vexim — Amazon Operations Dashboard',
    description: 'Pilot dashboard for contribution profit, inventory & recommendations',
  };
}

export default function DashboardPage() {
  const [skus, setSkus] = React.useState<any[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    async function fetchSkus() {
      try {
        const { data, err } = await supabase
          .from('amazon_skus')
          .select('*')
          .order('contribution_profit', { ascending: false });

        if (err) throw err;
        setSkus(data);
      } catch (e: any) {
        setError(e.message);
      } finally {
        setLoading(false);
      }
    }
    fetchSkus();
  }, []);

  if (loading) return <p>Loading...</p>;
  if (error) return <p style={{ color: 'red' }}>Error: {error}</p>;

  return (
    <section className="p-6 bg-gray-50 min-h-screen">
      <h1 className="text-2xl font-bold mb-6">Vexim Dashboard</h1>
      <div className="overflow-x-auto">
        <table className="w-full border-collapse border-border">
          <thead>
            <tr>
              <th className="border border-border px-4 py-2 text-left">ASIN</th>
              <th className="border border-border px-4 py-2 text-left">Title</th>
              <th className="border border-border px-4 py-2 text-right">Contribution Profit</th>
              <th className="border border-border px-4 py-2 text-center">Stockout Risk</th>
              <th className="border border-border px-4 py-2 text-left">Actions</th>
            </tr>
          </thead>
          <tbody>
            {skus.map((sku) => (
              <tr key={sku.id} className="hover:bg-white/50 transition">
                <td className="border border-border px-4 py-2">{sku.asin}</td>
                <td className="border border-border px-4 py-2 truncate">{sku.title}</td>
                <td className="border border-border px-4 py-2 text-right font-mono">
                  ${sku.contribution_profit?.toFixed(2) || '—'}
                </td>
                <td className="border border-border px-4 py-2 text-center">
                  {sku.stockout_risk_score?.toFixed(1) || '—'}
                </td>
                <td className="border border-border px-4 py-2">
                  <button
                    className="px-2 py-1 text-sm text-blue-600 underline"
                    onClick =(() => window.open(`/recommendations/${sku.id}`, '_blank'))
                  >
                    Generate rec
                  </button>
                </td>
              </tr>
            ))}
            {skus.length === 0 && (
              <tr>
                <td colSpan={5} className="text-center py-8">
                  No ASINs found. <a href="/add-sku" className="text-blue-600 underline">Add first SKU</a>
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}