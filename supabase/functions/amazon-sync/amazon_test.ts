// deno test supabase/functions/amazon-sync/amazon_test.ts
function assertEquals(a: unknown, b: unknown) { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`assertEquals\n  got:  ${x}\n  want: ${y}`); }
import { mapOrders, mapReturns, mapSalesTraffic, mapAdsAdvertised, mapInventory, parseTsv } from './amazon.ts';

Deno.test('parseTsv + mapOrders map đúng key hợp đồng', () => {
  const tsv = 'amazon-order-id\tpurchase-date\torder-status\tfulfillment-channel\tsku\tasin\tquantity\titem-price\tcurrency\n111-1\t2026-09-01T10:15:00+00:00\tShipped\tAFN\tVX-1\tB08N5RRNJC\t2\t49.98\tUSD\n';
  const rows = mapOrders(tsv);
  assertEquals(rows.length, 1);
  assertEquals(rows[0], { order_id: '111-1', order_date: '2026-09-01T10:15:00+00:00', status: 'Shipped', fulfillment_channel: 'AFN', asin: 'B08N5RRNJC', sku: 'VX-1', quantity: '2', item_sales: '49.98', currency: 'USD' });
  assertEquals(parseTsv('').rows.length, 0);
});

Deno.test('mapReturns bỏ ô trống', () => {
  const tsv = 'return-date\torder-id\tsku\tasin\tquantity\tdetailed-disposition\treason\tstatus\tlicense-plate-number\tcustomer-comments\n2026-09-03\t111-1\tVX-1\tB08N5RRNJC\t1\tSELLABLE\tUNWANTED_ITEM\tUnit returned\tLPN1\t\n';
  const r = mapReturns(tsv)[0];
  assertEquals(r.customer_comment, undefined);
  assertEquals(r.reason, 'UNWANTED_ITEM');
});

Deno.test('mapSalesTraffic đọc JSON Brand Analytics', () => {
  const j = JSON.stringify({ salesAndTrafficByAsin: [{ date: '2026-09-01', childAsin: 'B08N5RRNJC', salesByAsin: { unitsOrdered: 6, orderedProductSales: { amount: 149.94, currencyCode: 'USD' } }, trafficByAsin: { sessions: 120, pageViews: 151, buyBoxPercentage: 98, unitSessionPercentage: 5 } }] });
  const r = mapSalesTraffic(j)[0];
  assertEquals(r, { date: '2026-09-01', asin: 'B08N5RRNJC', sessions: '120', page_views: '151', units_ordered: '6', ordered_product_sales: '149.94', buy_box_pct: '98', unit_session_pct: '5' });
});

Deno.test('mapAdsAdvertised + mapInventory', () => {
  const r = mapAdsAdvertised([{ date: '2026-09-01', campaignName: 'SP', adGroupName: 'AG', advertisedAsin: 'B08N5RRNJC', impressions: 100, clicks: 3, cost: 1.5, purchases7d: 1, sales7d: 24.99 }])[0];
  assertEquals(r.spend, '1.5'); assertEquals(r.sales, '24.99'); assertEquals(r.campaign, 'SP');
  const inv = mapInventory('sku\tasin\tafn-fulfillable-quantity\tafn-inbound-shipped-quantity\nVX-1\tB08N5RRNJC\t40\t10\n', '2026-09-09')[0];
  assertEquals(inv, { date: '2026-09-09', sku: 'VX-1', asin: 'B08N5RRNJC', available: '40', inbound: '10' });
});
