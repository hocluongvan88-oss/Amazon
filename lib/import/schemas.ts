import { normalizeHeader } from './csv';

export type ImportKind = 'catalog' | 'cogs' | 'sales' | 'inventory' | 'fees' | 'orders' | 'ads' | 'reviews' | 'traffic' | 'returns' | 'search_terms' | 'promotions' | 'inventory_ledger';

/** Feed đi qua ingest server-side (021): trình duyệt chỉ gửi dòng thô; server validate/dry-run/commit */
export const SERVER_KINDS: ReadonlySet<ImportKind> = new Set<ImportKind>(['orders', 'ads', 'traffic', 'returns', 'search_terms', 'promotions', 'inventory_ledger', 'catalog', 'cogs', 'sales', 'inventory', 'fees', 'reviews']);

export type FieldDef = {
  key: string;
  label: string;
  required?: boolean;
  type: 'text' | 'number' | 'int' | 'date' | 'percent' | 'list' | 'bool';
  /** Tên cột thường gặp trong file Seller Central / nội bộ, đã normalize */
  aliases: string[];
  hint?: string;
};

export type ImportSchema = {
  kind: ImportKind;
  title: string;
  description: string;
  source: string;
  fields: FieldDef[];
  templateFile: string;
  /** Dữ liệu theo ngày (server derive sku_daily_snapshots từ bảng canonical) */
  daily?: boolean;
  /** Nhóm hiển thị */
  group: 'catalog' | 'daily' | 'ads' | 'other';
};

const ASIN: FieldDef = { key: 'asin', label: 'ASIN', required: true, type: 'text',
  aliases: ['asin', 'child asin', 'asin1', 'parent asin'] };
const SKU: FieldDef = { key: 'sku', label: 'SKU', type: 'text', aliases: ['sku', 'seller sku', 'merchant sku', 'msku'] };

export const SCHEMAS: Record<ImportKind, ImportSchema> = {
  catalog: {
    kind: 'catalog',
    group: 'catalog',
    title: 'Danh mục SKU',
    description: 'Tạo mới hoặc cập nhật ASIN, tên, giá, SKU nội bộ.',
    source: 'Seller Central → Inventory → Manage All Inventory → Download, hoặc file nội bộ',
    templateFile: '/templates/catalog.csv',
    fields: [
      ASIN, SKU,
      { key: 'title', label: 'Tên sản phẩm', required: true, type: 'text', aliases: ['title', 'item name', 'product name', 'name', 'ten san pham'] },
      { key: 'current_price', label: 'Giá bán', type: 'number', aliases: ['price', 'current price', 'your price', 'gia', 'gia ban'] },
      { key: 'list_price', label: 'Giá niêm yết', type: 'number', aliases: ['list price', 'msrp'] },
      { key: 'supplier', label: 'Nhà cung cấp', type: 'text', aliases: ['supplier', 'vendor', 'nha cung cap'] },
      { key: 'lead_time_days', label: 'Lead time (ngày)', type: 'int', aliases: ['lead time', 'lead time days', 'lead time ngay'] },
      { key: 'reorder_point', label: 'Điểm đặt hàng lại', type: 'int', aliases: ['reorder point', 'rop', 'diem dat hang lai'] },
    ],
  },
  cogs: {
    kind: 'cogs',
    group: 'catalog',
    title: 'Giá vốn (COGS)',
    description: 'Ghi vào lịch sử COGS theo ngày hiệu lực; giá vốn hiện tại của SKU tự cập nhật.',
    source: 'File kế toán / ERP nội bộ',
    templateFile: '/templates/cogs.csv',
    fields: [
      ASIN,
      { key: 'cogs', label: 'COGS (USD)', required: true, type: 'number', aliases: ['cogs', 'cost', 'unit cost', 'gia von'] },
      { key: 'landed_cost', label: 'Landed cost', type: 'number', aliases: ['landed cost', 'landed'] },
      { key: 'effective_from', label: 'Hiệu lực từ', type: 'date', aliases: ['effective from', 'effective date', 'date', 'ngay hieu luc'], hint: 'YYYY-MM-DD, mặc định hôm nay' },
      { key: 'note', label: 'Ghi chú', type: 'text', aliases: ['note', 'notes', 'ghi chu'] },
    ],
  },
  sales: {
    kind: 'sales',
    group: 'catalog',
    title: 'Doanh số 30 ngày',
    description: 'Cập nhật đơn vị bán, doanh thu, sessions 30 ngày gần nhất theo ASIN (child).',
    source: 'Seller Central → Reports → Business Reports → Detail Page Sales and Traffic by Child Item (chọn 30 ngày)',
    templateFile: '/templates/sales.csv',
    fields: [
      { ...ASIN, aliases: ['child asin', 'asin', '(child) asin'] },
      { key: 'sales_last_30d', label: 'Đơn vị bán', required: true, type: 'int', aliases: ['units ordered', 'units', 'quantity', 'so luong ban'] },
      { key: 'revenue_last_30d', label: 'Doanh thu', type: 'number', aliases: ['ordered product sales', 'revenue', 'sales', 'doanh thu'] },
      { key: 'sessions_last_30d', label: 'Sessions', type: 'int', aliases: ['sessions', 'sessions total', 'sessions - total'] },
    ],
  },
  inventory: {
    kind: 'inventory',
    group: 'catalog',
    title: 'Tồn kho FBA',
    description: 'Cập nhật tồn kho khả dụng theo ASIN.',
    source: 'Seller Central → Inventory → FBA Inventory → Download, hoặc Reports → Fulfillment → Manage FBA Inventory',
    templateFile: '/templates/inventory.csv',
    fields: [
      ASIN, SKU,
      { key: 'inventory_qty', label: 'Tồn khả dụng', required: true, type: 'int', aliases: ['available', 'afn fulfillable quantity', 'fulfillable quantity', 'quantity available', 'ton kho'] },
      { key: 'inventory_inbound', label: 'Đang về (inbound)', required: false, type: 'int', aliases: ['inbound', 'afn inbound shipped quantity', 'inbound quantity', 'dang ve'] },
    ],
  },
  fees: {
    kind: 'fees',
    group: 'catalog',
    title: 'Phí FBA & referral',
    description: 'Cập nhật phí FBA/đơn vị và % referral theo ASIN.',
    source: 'Seller Central → Reports → Fulfillment → Fee Preview',
    templateFile: '/templates/fees.csv',
    fields: [
      ASIN, SKU,
      { key: 'fee_per_unit', label: 'Phí FBA / đơn vị', required: true, type: 'number', aliases: ['estimated fee total', 'fba fees', 'fulfillment fee', 'expected fulfillment fee per unit', 'fee per unit', 'phi fba'] },
      { key: 'referral_fee_pct', label: 'Referral (%)', type: 'number', aliases: ['referral fee pct', 'referral pct', 'referral %', 'phi referral'], hint: 'Nếu file chỉ có số tiền referral, để trống – hệ thống giữ % hiện tại' },
    ],
  },
  orders: {
    kind: 'orders',
    group: 'daily',
    title: 'Đơn hàng (All Orders)',
    description: 'Từng dòng đơn hàng → bảng orders chuẩn; hệ thống tự gộp theo ngày + ASIN cho velocity, biểu đồ, forecast. Đơn Cancelled được lưu nhưng không tính doanh số.',
    source: 'Seller Central → Reports → Fulfillment → All Orders (by order date), tối đa 30 ngày/file; hoặc Order Reports',
    templateFile: '/templates/orders.csv',
    daily: true,
    fields: [
      { key: 'order_id', label: 'Mã đơn', required: true, type: 'text', aliases: ['amazon-order-id', 'amazon order id', 'order id', 'order-id', 'ma don'] },
      { key: 'order_date', label: 'Ngày đặt hàng', required: true, type: 'date', aliases: ['purchase date', 'purchase-date', 'order date', 'date', 'ngay'] },
      { ...ASIN }, SKU,
      { key: 'quantity', label: 'Số lượng', required: true, type: 'int', aliases: ['quantity', 'quantity-shipped', 'quantity shipped', 'qty', 'units'] },
      { key: 'item_sales', label: 'Tiền hàng (dòng)', type: 'number', aliases: ['item price', 'item-price', 'product sales', 'price'], hint: 'Tổng tiền của dòng, không phải đơn giá' },
      { key: 'status', label: 'Trạng thái đơn', type: 'text', aliases: ['order status', 'order-status', 'status'], hint: 'Cancelled → không tính doanh số' },
      { key: 'fulfillment_channel', label: 'Kênh (AFN/MFN)', type: 'text', aliases: ['fulfillment-channel', 'fulfillment channel', 'channel'] },
      { key: 'currency', label: 'Tiền tệ', type: 'text', aliases: ['currency'] },
    ],
  },
  ads: {
    kind: 'ads',
    group: 'ads',
    title: 'Quảng cáo theo ngày (Sponsored Products)',
    description: 'Chi phí, doanh thu QC, click, hiển thị theo ngày. Chấp nhận report theo ASIN quảng cáo, keyword hoặc campaign.',
    source: 'Ads console → Measurement & Reporting → Sponsored Products → Advertised product (khuyến nghị) / Targeting / Campaign, Daily',
    templateFile: '/templates/ads.csv',
    daily: true,
    fields: [
      { key: 'date', label: 'Ngày', required: true, type: 'date', aliases: ['date', 'start date', 'ngay'] },
      { key: 'asin', label: 'ASIN quảng cáo', type: 'text', aliases: ['advertised asin', 'asin'], hint: 'Bắt buộc nếu muốn gắn chi phí vào ASIN' },
      { key: 'campaign', label: 'Campaign', type: 'text', aliases: ['campaign name', 'campaign'] },
      { key: 'ad_group', label: 'Ad group', type: 'text', aliases: ['ad group name', 'ad group'] },
      { key: 'keyword_text', label: 'Keyword / target', type: 'text', aliases: ['targeting', 'keyword', 'keyword text'] },
      { key: 'match_type', label: 'Match type', type: 'text', aliases: ['match type'] },
      { key: 'impressions', label: 'Hiển thị', type: 'int', aliases: ['impressions'] },
      { key: 'clicks', label: 'Clicks', type: 'int', aliases: ['clicks'] },
      { key: 'spend', label: 'Chi phí', required: true, type: 'number', aliases: ['spend', 'cost', 'chi phi'] },
      { key: 'orders', label: 'Đơn QC', type: 'int', aliases: ['7 day total orders (#)', '7 day total orders', 'orders', '14 day total orders (#)'] },
      { key: 'sales', label: 'Doanh thu QC', type: 'number', aliases: ['7 day total sales', '7 day total sales ', 'sales', '14 day total sales', 'doanh thu'] },
    ],
  },
  traffic: {
    kind: 'traffic',
    group: 'daily',
    title: 'Sessions & chuyển đổi theo ngày',
    description: 'Sessions, page views, buy box %, unit session % theo ngày × ASIN con. Nguồn cho chẩn đoán chuyển đổi và CVR.',
    source: 'Seller Central → Reports → Business Reports → Detail Page Sales and Traffic by Child Item, chọn từng ngày (hoặc SP‑API Sales & Traffic, DAY)',
    templateFile: '/templates/traffic.csv',
    daily: true,
    fields: [
      { key: 'date', label: 'Ngày', required: true, type: 'date', aliases: ['date', 'ngay'] },
      { ...ASIN, aliases: ['(child) asin', 'child asin', 'asin'] },
      { key: 'sessions', label: 'Sessions', type: 'int', aliases: ['sessions - total', 'sessions total', 'sessions'] },
      { key: 'page_views', label: 'Page views', type: 'int', aliases: ['page views - total', 'page views total', 'page views'] },
      { key: 'units_ordered', label: 'Đơn vị bán', type: 'int', aliases: ['units ordered', 'units'] },
      { key: 'ordered_product_sales', label: 'Doanh thu', type: 'number', aliases: ['ordered product sales', 'revenue'] },
      { key: 'buy_box_pct', label: 'Buy Box %', type: 'percent', aliases: ['featured offer (buy box) percentage', 'buy box percentage', 'buy box %'] },
      { key: 'unit_session_pct', label: 'Unit session %', type: 'percent', aliases: ['unit session percentage', 'unit session %', 'conversion'] },
      { key: 'impressions', label: 'Hiển thị (SQP)', type: 'int', aliases: ['impressions'] },
      { key: 'clicks', label: 'Clicks (SQP)', type: 'int', aliases: ['clicks'] },
    ],
  },
  returns: {
    kind: 'returns',
    group: 'daily',
    title: 'Trả hàng / hoàn tiền',
    description: 'Từng dòng trả hàng với lý do, tình trạng, số tiền hoàn. Nguồn cho phân tích returns ↔ review ↔ nội dung.',
    source: 'Seller Central → Reports → Fulfillment → FBA customer returns; hoặc Manage Returns export',
    templateFile: '/templates/returns.csv',
    daily: true,
    fields: [
      { key: 'return_date', label: 'Ngày trả', required: true, type: 'date', aliases: ['return-date', 'return date', 'date', 'ngay'] },
      { key: 'order_id', label: 'Mã đơn', type: 'text', aliases: ['order-id', 'order id', 'amazon-order-id'] },
      ASIN, SKU,
      { key: 'quantity', label: 'Số lượng', required: true, type: 'int', aliases: ['quantity', 'qty'] },
      { key: 'reason', label: 'Lý do', type: 'text', aliases: ['reason', 'return reason'] },
      { key: 'customer_comment', label: 'Khách ghi chú', type: 'text', aliases: ['customer-comments', 'customer comments', 'comment'] },
      { key: 'refund_amount', label: 'Tiền hoàn', type: 'number', aliases: ['refund amount', 'refund', 'amount'] },
      { key: 'disposition', label: 'Tình trạng hàng', type: 'text', aliases: ['detailed-disposition', 'disposition'] },
      { key: 'status', label: 'Trạng thái', type: 'text', aliases: ['status'] },
      { key: 'return_ref', label: 'LPN / RMA', type: 'text', aliases: ['license-plate-number', 'lpn', 'rma'] },
    ],
  },
  search_terms: {
    kind: 'search_terms',
    group: 'ads',
    title: 'Search term (Sponsored Products)',
    description: 'Từ khoá khách thực sự tìm → click/đơn. Nguồn cho cơ hội từ khoá và negative keyword.',
    source: 'Ads console → Measurement & Reporting → Sponsored Products → Search term, Daily',
    templateFile: '/templates/search_terms.csv',
    daily: true,
    fields: [
      { key: 'date', label: 'Ngày', required: true, type: 'date', aliases: ['date', 'start date'] },
      { key: 'campaign', label: 'Campaign', type: 'text', aliases: ['campaign name', 'campaign'] },
      { key: 'ad_group', label: 'Ad group', type: 'text', aliases: ['ad group name', 'ad group'] },
      { key: 'keyword_text', label: 'Keyword / target', type: 'text', aliases: ['targeting', 'keyword'] },
      { key: 'match_type', label: 'Match type', type: 'text', aliases: ['match type'] },
      { key: 'search_term', label: 'Search term', required: true, type: 'text', aliases: ['customer search term', 'search term'] },
      { key: 'asin', label: 'ASIN quảng cáo', type: 'text', aliases: ['advertised asin', 'asin'] },
      { key: 'impressions', label: 'Hiển thị', type: 'int', aliases: ['impressions'] },
      { key: 'clicks', label: 'Clicks', type: 'int', aliases: ['clicks'] },
      { key: 'spend', label: 'Chi phí', type: 'number', aliases: ['spend', 'cost'] },
      { key: 'orders', label: 'Đơn', type: 'int', aliases: ['7 day total orders (#)', '7 day total orders', 'orders'] },
      { key: 'sales', label: 'Doanh thu', type: 'number', aliases: ['7 day total sales', 'sales'] },
    ],
  },
  promotions: {
    kind: 'promotions',
    group: 'other',
    title: 'Khuyến mãi / coupon / deal',
    description: 'Lịch khuyến mãi (nhập tay có audit) để đo tác động promo và tránh đọc nhầm baseline.',
    source: 'Seller Central → Advertising → Coupons / Deals / Promotions → ghi lại theo file mẫu',
    templateFile: '/templates/promotions.csv',
    fields: [
      { key: 'promo_id', label: 'Mã KM', required: true, type: 'text', aliases: ['promo id', 'promotion id', 'coupon id', 'deal id', 'id'] },
      { key: 'promo_type', label: 'Loại', required: true, type: 'text', aliases: ['type', 'promo type'], hint: 'coupon | lightning_deal | best_deal | promotion | prime_exclusive' },
      { key: 'name', label: 'Tên', type: 'text', aliases: ['name', 'title'] },
      { key: 'asins', label: 'ASIN (nhiều, cách bằng ;)', required: true, type: 'list', aliases: ['asins', 'asin', 'products'] },
      { key: 'start_at', label: 'Bắt đầu', required: true, type: 'date', aliases: ['start date', 'start', 'start_at'] },
      { key: 'end_at', label: 'Kết thúc', type: 'date', aliases: ['end date', 'end', 'end_at'] },
      { key: 'discount_type', label: 'Kiểu giảm', type: 'text', aliases: ['discount type'], hint: 'percent | amount' },
      { key: 'discount_value', label: 'Mức giảm', type: 'number', aliases: ['discount', 'discount value'] },
      { key: 'budget', label: 'Ngân sách', type: 'number', aliases: ['budget'] },
      { key: 'status', label: 'Trạng thái', type: 'text', aliases: ['status'] },
      { key: 'margin_note', label: 'Ghi chú biên', type: 'text', aliases: ['note', 'margin note'] },
    ],
  },
  inventory_ledger: {
    kind: 'inventory_ledger',
    group: 'daily',
    title: 'Sổ tồn kho FBA chi tiết',
    description: 'Tồn theo ngày × ASIN × SKU × kho: available, reserved, inbound, unfulfillable, aged. Tự cập nhật tồn hiện tại của SKU.',
    source: 'Seller Central → Reports → Fulfillment → Manage FBA Inventory / Inventory Age; thêm cột ngày chụp',
    templateFile: '/templates/inventory_ledger.csv',
    daily: true,
    fields: [
      { key: 'date', label: 'Ngày chụp', required: true, type: 'date', aliases: ['snapshot-date', 'snapshot date', 'date', 'ngay'] },
      ASIN, SKU,
      { key: 'fc', label: 'Kho (FC)', type: 'text', aliases: ['fulfillment-center-id', 'fulfillment center', 'fc', 'warehouse'] },
      { key: 'available', label: 'Khả dụng', type: 'int', aliases: ['afn-fulfillable-quantity', 'afn fulfillable quantity', 'available', 'fulfillable'] },
      { key: 'reserved', label: 'Reserved', type: 'int', aliases: ['afn-reserved-quantity', 'reserved quantity', 'reserved'] },
      { key: 'inbound', label: 'Inbound', type: 'int', aliases: ['afn-inbound-shipped-quantity', 'inbound shipped', 'inbound'] },
      { key: 'unfulfillable', label: 'Unfulfillable', type: 'int', aliases: ['afn-unsellable-quantity', 'unsellable', 'unfulfillable'] },
      { key: 'stranded', label: 'Stranded', type: 'int', aliases: ['stranded'] },
      { key: 'aged_90', label: 'Tuổi 91–180', type: 'int', aliases: ['inv-age-91-to-180-days', 'aged 90'] },
      { key: 'aged_180', label: 'Tuổi 181–270', type: 'int', aliases: ['inv-age-181-to-270-days', 'aged 180'] },
      { key: 'aged_270', label: 'Tuổi 271–365', type: 'int', aliases: ['inv-age-271-to-365-days', 'aged 270'] },
      { key: 'aged_365', label: 'Tuổi 365+', type: 'int', aliases: ['inv-age-365-plus-days', 'aged 365'] },
    ],
  },
  reviews: {
    kind: 'reviews',
    group: 'other',
    title: 'Review khách hàng',
    description: 'Nhập review để phân loại chủ đề, triage sao thấp và mở ticket VOC. Chỉ lắng nghe – không có hành động tác động rating.',
    source: 'Seller Central → Brands → Customer Reviews → export, hoặc file tổng hợp từ công cụ bên thứ ba',
    templateFile: '/templates/reviews.csv',
    fields: [
      ASIN,
      { key: 'rating', label: 'Số sao (1‑5)', required: true, type: 'int', aliases: ['rating', 'stars', 'star rating', 'sao'] },
      { key: 'title', label: 'Tiêu đề', required: false, type: 'text', aliases: ['title', 'review title', 'headline', 'tieu de'] },
      { key: 'body', label: 'Nội dung', required: true, type: 'text', aliases: ['body', 'review', 'review text', 'content', 'comment', 'noi dung'] },
      { key: 'reviewed_at', label: 'Ngày review', required: false, type: 'date', aliases: ['date', 'review date', 'reviewed at', 'ngay'] },
      { key: 'reviewer_id', label: 'Mã người review', required: false, type: 'text', aliases: ['reviewer id', 'reviewer', 'profile id', 'author'] },
      { key: 'verified_purchase', label: 'Đã mua (verified)', required: false, type: 'bool', aliases: ['verified', 'verified purchase'] },
    ],
  },
};

/** Tự đoán mapping cột file → field theo alias */
export function autoMap(headers: string[], schema: ImportSchema): Record<string, string | ''> {
  const norm = headers.map((h) => ({ raw: h, n: normalizeHeader(h) }));
  const map: Record<string, string | ''> = {};
  for (const f of schema.fields) {
    const hit = norm.find((h) => f.aliases.includes(h.n)) ?? norm.find((h) => f.aliases.some((a) => h.n.includes(a)));
    map[f.key] = hit?.raw ?? '';
  }
  return map;
}
