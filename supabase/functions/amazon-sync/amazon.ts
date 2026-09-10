// Amazon SP-API + Ads API — READ-ONLY client cho worker. Không có hàm ghi nào ở đây.
// Secret chỉ tồn tại trong bộ nhớ của Edge Function trong 1 lần chạy.

export type Region = 'na' | 'eu' | 'fe';
export type SpCred = { client_id: string; client_secret: string; refresh_token: string };
export type AdsCred = SpCred & { profile_id?: string };

export class AmazonError extends Error {
  constructor(message: string, public cls: 'auth' | 'rate_limit' | 'permission' | 'amazon' | 'parse' | 'network', public retryable: boolean, public retryAfter?: number) {
    super(message);
  }
}

const SP_ENDPOINT: Record<Region, string> = {
  na: 'https://sellingpartnerapi-na.amazon.com',
  eu: 'https://sellingpartnerapi-eu.amazon.com',
  fe: 'https://sellingpartnerapi-fe.amazon.com',
};
const ADS_ENDPOINT: Record<Region, string> = {
  na: 'https://advertising-api.amazon.com',
  eu: 'https://advertising-api-eu.amazon.com',
  fe: 'https://advertising-api-fe.amazon.com',
};
/** marketplaceId → region (chỉ các marketplace phổ biến; config.region ghi đè) */
export const MARKETPLACE: Record<string, { id: string; region: Region }> = {
  US: { id: 'ATVPDKIKX0DER', region: 'na' }, CA: { id: 'A2EUQ1WTGCTBG2', region: 'na' }, MX: { id: 'A1AM78C64UM0Y8', region: 'na' }, BR: { id: 'A2Q3Y263D00KWC', region: 'na' },
  UK: { id: 'A1F83G8C2ARO7P', region: 'eu' }, DE: { id: 'A1PA6795UKMFR9', region: 'eu' }, FR: { id: 'A13V1IB3VIYZZH', region: 'eu' }, IT: { id: 'APJ6JRA9NG5V4', region: 'eu' }, ES: { id: 'A1RKKUPIHCS9HS', region: 'eu' },
  JP: { id: 'A1VC38T7YXB528', region: 'fe' }, AU: { id: 'A39IBJ37TRP1C6', region: 'fe' }, SG: { id: 'A19VAU5U5O7RUS', region: 'fe' },
};

export async function lwaToken(c: SpCred): Promise<string> {
  let res: Response;
  try {
    res = await fetch('https://api.amazon.com/auth/o2/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: c.refresh_token, client_id: c.client_id, client_secret: c.client_secret }),
    });
  } catch (e) { throw new AmazonError(`LWA network: ${String(e)}`, 'network', true); }
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new AmazonError(`LWA ${res.status}: ${j.error ?? ''} ${j.error_description ?? ''}`.trim(), 'auth', false);
  return j.access_token as string;
}

function classify(status: number, body: string): AmazonError {
  if (status === 401 || status === 403) return new AmazonError(`Amazon ${status}: ${body.slice(0, 300)}`, status === 403 && /Unauthorized|role|permission/i.test(body) ? 'permission' : 'auth', false);
  if (status === 429) return new AmazonError('Amazon 429: rate limit', 'rate_limit', true, 90);
  if (status >= 500) return new AmazonError(`Amazon ${status}: ${body.slice(0, 300)}`, 'amazon', true, 120);
  return new AmazonError(`Amazon ${status}: ${body.slice(0, 300)}`, 'amazon', false);
}

async function call(url: string, init: RequestInit): Promise<Response> {
  let res: Response;
  try { res = await fetch(url, init); } catch (e) { throw new AmazonError(`network: ${String(e)}`, 'network', true, 60); }
  if (!res.ok) throw classify(res.status, await res.text().catch(() => ''));
  return res;
}

async function gunzipText(res: Response, compressed: boolean): Promise<string> {
  if (!compressed) return await res.text();
  const ds = new DecompressionStream('gzip');
  return await new Response(res.body!.pipeThrough(ds)).text();
}

// ---------------- SP-API Reports (async) ----------------
export type SpReportSpec = { reportType: string; marketplaceIds: string[]; dataStartTime?: string; dataEndTime?: string; reportOptions?: Record<string, string> };

export async function spCreateReport(region: Region, token: string, spec: SpReportSpec): Promise<string> {
  const res = await call(`${SP_ENDPOINT[region]}/reports/2021-06-30/reports`, {
    method: 'POST', headers: { 'x-amz-access-token': token, 'Content-Type': 'application/json' }, body: JSON.stringify(spec),
  });
  const j = await res.json();
  return j.reportId as string;
}
export async function spGetReport(region: Region, token: string, reportId: string): Promise<{ processingStatus: string; reportDocumentId?: string }> {
  const res = await call(`${SP_ENDPOINT[region]}/reports/2021-06-30/reports/${encodeURIComponent(reportId)}`, { headers: { 'x-amz-access-token': token } });
  return await res.json();
}
export async function spDownloadDocument(region: Region, token: string, documentId: string): Promise<string> {
  const meta = await (await call(`${SP_ENDPOINT[region]}/reports/2021-06-30/documents/${encodeURIComponent(documentId)}`, { headers: { 'x-amz-access-token': token } })).json();
  let res: Response;
  try { res = await fetch(meta.url); } catch (e) { throw new AmazonError(`download: ${String(e)}`, 'network', true, 60); }
  if (!res.ok) throw new AmazonError(`download ${res.status}`, 'amazon', true, 60);
  return await gunzipText(res, meta.compressionAlgorithm === 'GZIP');
}

// ---------------- Ads API v3 Reports (async) ----------------
export type AdsReportSpec = { name: string; startDate: string; endDate: string; configuration: { adProduct: 'SPONSORED_PRODUCTS'; groupBy: string[]; columns: string[]; reportTypeId: string; timeUnit: 'DAILY'; format: 'GZIP_JSON' } };

function adsHeaders(c: AdsCred, token: string, profile: string): HeadersInit {
  return { Authorization: `Bearer ${token}`, 'Amazon-Advertising-API-ClientId': c.client_id, 'Amazon-Advertising-API-Scope': profile };
}
export async function adsListProfiles(region: Region, c: AdsCred, token: string): Promise<{ profileId: number; countryCode: string; accountInfo: { type: string; name: string } }[]> {
  const res = await call(`${ADS_ENDPOINT[region]}/v2/profiles`, { headers: { Authorization: `Bearer ${token}`, 'Amazon-Advertising-API-ClientId': c.client_id } });
  return await res.json();
}
export async function adsCreateReport(region: Region, c: AdsCred, token: string, profile: string, spec: AdsReportSpec): Promise<string> {
  const res = await call(`${ADS_ENDPOINT[region]}/reporting/reports`, {
    method: 'POST', headers: { ...adsHeaders(c, token, profile), 'Content-Type': 'application/vnd.createasyncreportrequest.v3+json' }, body: JSON.stringify(spec),
  });
  const j = await res.json();
  return j.reportId as string;
}
export async function adsGetReport(region: Region, c: AdsCred, token: string, profile: string, reportId: string): Promise<{ status: string; url?: string; failureReason?: string }> {
  const res = await call(`${ADS_ENDPOINT[region]}/reporting/reports/${encodeURIComponent(reportId)}`, { headers: adsHeaders(c, token, profile) });
  return await res.json();
}
export async function adsDownload(url: string): Promise<unknown[]> {
  let res: Response;
  try { res = await fetch(url); } catch (e) { throw new AmazonError(`download: ${String(e)}`, 'network', true, 60); }
  if (!res.ok) throw new AmazonError(`download ${res.status}`, 'amazon', true, 60);
  const txt = await gunzipText(res, true);
  try { return JSON.parse(txt) as unknown[]; } catch { throw new AmazonError('Ads report không phải JSON', 'parse', false); }
}

// ---------------- Parsers → dòng thô theo key của ingest_feed_specs ----------------
export type RawRow = Record<string, string>;

export function parseTsv(text: string): { headers: string[]; rows: string[][] } {
  const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/).filter((l) => l.length > 0);
  if (lines.length === 0) return { headers: [], rows: [] };
  const headers = lines[0].split('\t').map((h) => h.trim().toLowerCase());
  return { headers, rows: lines.slice(1).map((l) => l.split('\t')) };
}
function pick(headers: string[], row: string[], ...names: string[]): string {
  for (const n of names) { const i = headers.indexOf(n); if (i >= 0 && row[i] != null && row[i] !== '') return row[i]; }
  return '';
}
const clean = (o: RawRow): RawRow => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== '' && v != null));

/** GET_FLAT_FILE_ALL_ORDERS_DATA_BY_LAST_UPDATE_GENERAL → import_kind orders */
export function mapOrders(text: string): RawRow[] {
  const { headers, rows } = parseTsv(text);
  return rows.map((r) => clean({
    order_id: pick(headers, r, 'amazon-order-id'), order_date: pick(headers, r, 'purchase-date'), status: pick(headers, r, 'order-status'),
    fulfillment_channel: pick(headers, r, 'fulfillment-channel'), asin: pick(headers, r, 'asin'), sku: pick(headers, r, 'sku'),
    quantity: pick(headers, r, 'quantity'), item_sales: pick(headers, r, 'item-price'), currency: pick(headers, r, 'currency'),
  }));
}
/** GET_FBA_FULFILLMENT_CUSTOMER_RETURNS_DATA → returns */
export function mapReturns(text: string): RawRow[] {
  const { headers, rows } = parseTsv(text);
  return rows.map((r) => clean({
    return_date: pick(headers, r, 'return-date'), order_id: pick(headers, r, 'order-id'), sku: pick(headers, r, 'sku'), asin: pick(headers, r, 'asin'),
    quantity: pick(headers, r, 'quantity'), disposition: pick(headers, r, 'detailed-disposition'), reason: pick(headers, r, 'reason'), status: pick(headers, r, 'status'),
    return_ref: pick(headers, r, 'license-plate-number'), customer_comment: pick(headers, r, 'customer-comments'),
  }));
}
/** GET_FBA_MYI_UNSUPPRESSED_INVENTORY_DATA → inventory_ledger (snapshot hôm nay; report không có FC) */
export function mapInventory(text: string, today: string): RawRow[] {
  const { headers, rows } = parseTsv(text);
  return rows.map((r) => clean({
    date: today, sku: pick(headers, r, 'sku', 'seller-sku'), asin: pick(headers, r, 'asin'), fc: '',
    available: pick(headers, r, 'afn-fulfillable-quantity'), reserved: pick(headers, r, 'afn-reserved-quantity'), inbound: pick(headers, r, 'afn-inbound-shipped-quantity'),
    unfulfillable: pick(headers, r, 'afn-unsellable-quantity'),
  }));
}
/** GET_SALES_AND_TRAFFIC_REPORT (JSON, CHILD, DAY) → traffic */
export function mapSalesTraffic(text: string): RawRow[] {
  let j: { salesAndTrafficByAsin?: Array<Record<string, unknown>> };
  try { j = JSON.parse(text); } catch { throw new AmazonError('Sales&Traffic không phải JSON', 'parse', false); }
  const out: RawRow[] = [];
  for (const it of j.salesAndTrafficByAsin ?? []) {
    const s = (it.salesByAsin ?? {}) as Record<string, unknown>; const t = (it.trafficByAsin ?? {}) as Record<string, unknown>;
    const ops = (s.orderedProductSales ?? {}) as { amount?: number };
    out.push(clean({
      date: String(it.date ?? ''), asin: String(it.childAsin ?? it.parentAsin ?? ''),
      sessions: str(t.sessions), page_views: str(t.pageViews), units_ordered: str(s.unitsOrdered), ordered_product_sales: str(ops.amount),
      buy_box_pct: str(t.buyBoxPercentage), unit_session_pct: str(t.unitSessionPercentage),
    }));
  }
  return out;
}
const str = (v: unknown) => (v == null ? '' : String(v));

/** Ads spAdvertisedProduct DAILY → ads */
export const ADS_ADVERTISED_COLUMNS = ['date', 'campaignName', 'campaignId', 'adGroupName', 'adGroupId', 'advertisedAsin', 'advertisedSku', 'impressions', 'clicks', 'cost', 'purchases7d', 'sales7d'];
export function mapAdsAdvertised(rows: unknown[]): RawRow[] {
  return (rows as Record<string, unknown>[]).map((r) => clean({
    date: str(r.date), asin: str(r.advertisedAsin), campaign: str(r.campaignName || r.campaignId), ad_group: str(r.adGroupName || r.adGroupId),
    impressions: str(r.impressions), clicks: str(r.clicks), spend: str(r.cost), orders: str(r.purchases7d), sales: str(r.sales7d),
  }));
}
/** Ads spSearchTerm DAILY → search_terms */
export const ADS_SEARCH_TERM_COLUMNS = ['date', 'campaignName', 'campaignId', 'adGroupName', 'adGroupId', 'keyword', 'keywordId', 'matchType', 'searchTerm', 'impressions', 'clicks', 'cost', 'purchases7d', 'sales7d'];
export function mapAdsSearchTerms(rows: unknown[]): RawRow[] {
  return (rows as Record<string, unknown>[]).map((r) => clean({
    date: str(r.date), campaign: str(r.campaignName || r.campaignId), ad_group: str(r.adGroupName || r.adGroupId), keyword_text: str(r.keyword), match_type: str(r.matchType),
    search_term: str(r.searchTerm), impressions: str(r.impressions), clicks: str(r.clicks), spend: str(r.cost), orders: str(r.purchases7d), sales: str(r.sales7d),
  }));
}
