import { normalizeHeader } from './csv';

export type ImportKind = 'catalog' | 'cogs' | 'sales' | 'inventory' | 'fees' | 'orders' | 'ads' | 'reviews';

export type FieldDef = {
  key: string;
  label: string;
  required?: boolean;
  type: 'text' | 'number' | 'int' | 'date';
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
  /** Dữ liệu theo ngày → ghi vào sku_daily_snapshots (gộp theo ngày + ASIN) */
  daily?: boolean;
};

const ASIN: FieldDef = { key: 'asin', label: 'ASIN', required: true, type: 'text',
  aliases: ['asin', 'child asin', 'asin1', 'parent asin'] };
const SKU: FieldDef = { key: 'sku', label: 'SKU', type: 'text', aliases: ['sku', 'seller sku', 'merchant sku', 'msku'] };

export const SCHEMAS: Record<ImportKind, ImportSchema> = {
  catalog: {
    kind: 'catalog',
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
    title: 'Đơn hàng theo ngày (All Orders)',
    description: 'Gộp theo ngày + ASIN → đơn vị & doanh thu từng ngày. Bỏ đơn Cancelled. Nguồn cho velocity, biểu đồ, forecast.',
    source: 'Seller Central → Reports → Fulfillment → All Orders (by order date), tối đa 30 ngày/file; hoặc Order Reports',
    templateFile: '/templates/orders.csv',
    daily: true,
    fields: [
      { key: 'date', label: 'Ngày đặt hàng', required: true, type: 'date', aliases: ['purchase date', 'purchase-date', 'order date', 'date', 'ngay'] },
      { ...ASIN },
      { key: 'quantity', label: 'Số lượng', required: true, type: 'int', aliases: ['quantity', 'quantity-shipped', 'quantity shipped', 'qty', 'units'] },
      { key: 'item_price', label: 'Tiền hàng (dòng)', type: 'number', aliases: ['item price', 'item-price', 'product sales', 'price'], hint: 'Tổng tiền của dòng, không phải đơn giá' },
      { key: 'order_status', label: 'Trạng thái đơn', type: 'text', aliases: ['order status', 'order-status', 'status'], hint: 'Dòng Cancelled sẽ bị bỏ' },
    ],
  },
  ads: {
    kind: 'ads',
    title: 'Quảng cáo theo ngày (Sponsored Products)',
    description: 'Chi phí, doanh thu quảng cáo, click, hiển thị từng ngày theo ASIN được quảng cáo.',
    source: 'Ads console → Measurement & Reporting → Sponsored Products → Advertised product, Daily',
    templateFile: '/templates/ads.csv',
    daily: true,
    fields: [
      { key: 'date', label: 'Ngày', required: true, type: 'date', aliases: ['date', 'start date', 'ngay'] },
      { key: 'asin', label: 'ASIN quảng cáo', required: true, type: 'text', aliases: ['advertised asin', 'asin'] },
      { key: 'ad_spend', label: 'Chi phí', required: true, type: 'number', aliases: ['spend', 'cost', 'chi phi'] },
      { key: 'ad_sales', label: 'Doanh thu QC', type: 'number', aliases: ['7 day total sales', '7 day total sales ', 'sales', '14 day total sales', 'doanh thu'] },
      { key: 'ad_clicks', label: 'Clicks', type: 'int', aliases: ['clicks'] },
      { key: 'ad_impressions', label: 'Hiển thị', type: 'int', aliases: ['impressions'] },
    ],
  },
  reviews: {
    kind: 'reviews',
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
      { key: 'verified_purchase', label: 'Đã mua (verified)', required: false, type: 'text', aliases: ['verified', 'verified purchase'] },
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
