import { normalizeHeader } from './csv';

export type ImportKind = 'catalog' | 'cogs' | 'sales' | 'inventory' | 'fees';

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
