/**
 * Đặc tả module A+ theo Amazon A+ Content Manager (Standard + cờ Premium).
 * Nguồn sự thật cho editor, preview, gói bàn giao. Bản SQL tương đương: aplus_module_specs (018).
 * Giới hạn ký tự/kích thước ảnh theo tài liệu A+ Content Manager (có thể lệch nhẹ theo marketplace → gate coi là block).
 */

export type FieldSpec =
  | { key: string; label: string; type: 'text'; max: number; required?: boolean; factable?: boolean }
  | { key: string; label: string; type: 'textarea'; max: number; required?: boolean; factable?: boolean }
  | { key: string; label: string; type: 'image'; minW: number; minH: number; required?: boolean }
  | { key: string; label: string; type: 'list'; count: number; item: FieldSpec[]; label_item?: string }
  | { key: string; label: string; type: 'table'; maxRows: number; cols: { key: string; label: string; max: number }[] };

export type ModuleSpec = { type: string; name: string; amazon_name: string; premium?: boolean; fields: FieldSpec[]; note?: string };

const img = (key: string, label: string, minW: number, minH: number, required = true): FieldSpec => ({ key, label, type: 'image', minW, minH, required });
const alt = (key = 'alt'): FieldSpec => ({ key, label: 'Alt‑text ảnh (từ khoá, ≤ 100)', type: 'text', max: 100, required: true });

export const APLUS_MODULES: ModuleSpec[] = [
  { type: 'standard_company_logo', name: 'Logo thương hiệu', amazon_name: 'Standard Company Logo', fields: [img('image', 'Logo 600×180', 600, 180), alt()] },
  { type: 'standard_image_header_text', name: 'Ảnh header + text', amazon_name: 'Standard Image Header With Text',
    fields: [img('image', 'Ảnh 970×600', 970, 600), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 150, required: true }, { key: 'subheadline', label: 'Sub‑headline', type: 'text', max: 150 }, { key: 'body', label: 'Body', type: 'textarea', max: 6000, factable: true }] },
  { type: 'standard_text', name: 'Text', amazon_name: 'Standard Text', fields: [{ key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body', type: 'textarea', max: 5000, required: true, factable: true }] },
  { type: 'standard_product_description_text', name: 'Mô tả sản phẩm (text)', amazon_name: 'Standard Product Description Text', fields: [{ key: 'body', label: 'Body', type: 'textarea', max: 6000, required: true, factable: true }] },
  { type: 'standard_single_left_image', name: '1 ảnh trái + text', amazon_name: 'Standard Single Left Image',
    fields: [img('image', 'Ảnh 300×300', 300, 300), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body', type: 'textarea', max: 1000, required: true, factable: true }] },
  { type: 'standard_single_right_image', name: '1 ảnh phải + text', amazon_name: 'Standard Single Right Image',
    fields: [img('image', 'Ảnh 300×300', 300, 300), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body', type: 'textarea', max: 1000, required: true, factable: true }] },
  { type: 'standard_single_image_highlights', name: '1 ảnh + điểm nổi bật', amazon_name: 'Standard Single Image & Highlights',
    fields: [img('image', 'Ảnh 300×300', 300, 300), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'subheadline', label: 'Sub‑headline', type: 'text', max: 200 }, { key: 'body', label: 'Body', type: 'textarea', max: 1000, factable: true },
      { key: 'highlights', label: 'Điểm nổi bật', type: 'list', count: 8, label_item: 'Bullet', item: [{ key: 'text', label: 'Bullet (≤ 100)', type: 'text', max: 100, factable: true }] }] },
  { type: 'standard_single_image_sidebar', name: '1 ảnh + sidebar', amazon_name: 'Standard Single Image & Sidebar',
    fields: [img('image', 'Ảnh chính 300×400', 300, 400), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body (≤ 500)', type: 'textarea', max: 500, required: true, factable: true },
      img('sidebar_image', 'Ảnh sidebar 350×175', 350, 175, false), { key: 'sidebar_headline', label: 'Sidebar headline', type: 'text', max: 160 }, { key: 'sidebar_body', label: 'Sidebar text', type: 'textarea', max: 500, factable: true }] },
  { type: 'standard_single_image_specs_detail', name: '1 ảnh + thông số', amazon_name: 'Standard Single Image & Specs Detail',
    fields: [img('image', 'Ảnh 300×300', 300, 300), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body', type: 'textarea', max: 1000, factable: true },
      { key: 'specs', label: 'Thông số', type: 'table', maxRows: 16, cols: [{ key: 'name', label: 'Tên (≤ 30)', max: 30 }, { key: 'value', label: 'Giá trị (≤ 500)', max: 500 }] }] },
  { type: 'standard_three_image_text', name: '3 ảnh + text', amazon_name: 'Standard Three Images & Text',
    fields: [{ key: 'headline', label: 'Headline chung', type: 'text', max: 200 }, { key: 'blocks', label: 'Khối', type: 'list', count: 3, label_item: 'Khối', item: [img('image', 'Ảnh 300×300', 300, 300), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body (≤ 1000)', type: 'textarea', max: 1000, factable: true }] }] },
  { type: 'standard_four_image_text', name: '4 ảnh + text', amazon_name: 'Standard Four Image & Text',
    fields: [{ key: 'headline', label: 'Headline chung', type: 'text', max: 200 }, { key: 'blocks', label: 'Khối', type: 'list', count: 4, label_item: 'Khối', item: [img('image', 'Ảnh 220×220', 220, 220), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body (≤ 1000)', type: 'textarea', max: 1000, factable: true }] }] },
  { type: 'standard_four_image_text_quadrant', name: '4 ảnh quadrant', amazon_name: 'Standard Four Image/Text Quadrant',
    fields: [{ key: 'blocks', label: 'Ô', type: 'list', count: 4, label_item: 'Ô', item: [img('image', 'Ảnh 135×135', 135, 135), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 140 }, { key: 'body', label: 'Body (≤ 1000)', type: 'textarea', max: 1000, factable: true }] }] },
  { type: 'standard_multiple_image_module_a', name: 'Nhiều ảnh (A)', amazon_name: 'Standard Multiple Image Module A',
    fields: [{ key: 'blocks', label: 'Ảnh', type: 'list', count: 4, label_item: 'Ảnh', item: [img('image', 'Ảnh 300×300', 300, 300), alt(), { key: 'caption', label: 'Caption', type: 'text', max: 200 }, { key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'body', label: 'Body (≤ 1000)', type: 'textarea', max: 1000, factable: true }] }] },
  { type: 'standard_image_text_overlay', name: 'Ảnh + text overlay (sáng/tối)', amazon_name: 'Standard Image & Light/Dark Text Overlay',
    fields: [img('image', 'Ảnh 970×300', 970, 300), alt(), { key: 'overlay', label: 'Kiểu overlay (light/dark)', type: 'text', max: 5 }, { key: 'headline', label: 'Headline', type: 'text', max: 70 }, { key: 'body', label: 'Body (≤ 300)', type: 'textarea', max: 300, factable: true }] },
  { type: 'standard_comparison_chart', name: 'Bảng so sánh', amazon_name: 'Standard Comparison Chart', note: 'Chỉ so sánh ASIN của chính thương hiệu.',
    fields: [{ key: 'products', label: 'Sản phẩm (2–6)', type: 'list', count: 6, label_item: 'Sản phẩm', item: [img('image', 'Ảnh 150×300', 150, 300), alt(), { key: 'asin', label: 'ASIN', type: 'text', max: 10, required: true }, { key: 'title', label: 'Tên hiển thị', type: 'text', max: 80 }] },
      { key: 'metrics', label: 'Chỉ tiêu (≤ 10)', type: 'table', maxRows: 10, cols: [{ key: 'name', label: 'Chỉ tiêu (≤ 20)', max: 20 }, { key: 'values', label: 'Giá trị theo sản phẩm (cách nhau bằng |)', max: 600 }] }] },
  { type: 'standard_tech_specs', name: 'Bảng thông số kỹ thuật', amazon_name: 'Standard Technical Specifications',
    fields: [{ key: 'headline', label: 'Headline', type: 'text', max: 160 }, { key: 'specs', label: 'Dòng (≤ 16)', type: 'table', maxRows: 16, cols: [{ key: 'name', label: 'Tên (≤ 30)', max: 30 }, { key: 'value', label: 'Giá trị (≤ 500)', max: 500 }] }] },
  { type: 'premium_full_image', name: 'Premium: ảnh full', amazon_name: 'Premium Full Image', premium: true, fields: [img('image', 'Ảnh 1464×600', 1464, 600), alt(), { key: 'headline', label: 'Headline', type: 'text', max: 80 }, { key: 'body', label: 'Body', type: 'textarea', max: 500, factable: true }] },
];

export const MODULE_BY_TYPE: Record<string, ModuleSpec> = Object.fromEntries(APLUS_MODULES.map((m) => [m.type, m]));
export const STANDARD_MAX_MODULES = 5;
export const PREMIUM_MAX_MODULES = 7;

/** Map type cũ (013/017) → type Amazon. */
export const LEGACY_TYPE_MAP: Record<string, string> = {
  standard_image_text: 'standard_single_left_image', image_header_text: 'standard_image_header_text', four_image_text: 'standard_four_image_text',
  comparison_chart: 'standard_comparison_chart', tech_specs: 'standard_tech_specs',
};

export type ModuleData = { type: string; [k: string]: unknown };

export function emptyModule(type: string): ModuleData {
  const spec = MODULE_BY_TYPE[type];
  const m: ModuleData = { type };
  for (const f of spec?.fields ?? []) {
    if (f.type === 'list') m[f.key] = Array.from({ length: Math.min(f.count, f.key === 'products' ? 2 : f.count) }, () => Object.fromEntries(f.item.map((i) => [i.key, i.type === 'image' ? { brief: '', url: '' } : ''])));
    else if (f.type === 'table') m[f.key] = [];
    else if (f.type === 'image') m[f.key] = { brief: '', url: '' };
    else m[f.key] = '';
  }
  return m;
}

/** Nâng cấp body cũ {header, body, image_brief} → cấu trúc mới. */
export function upgradeLegacyModule(m: Record<string, unknown>): ModuleData {
  const t = String(m.type ?? '');
  if (MODULE_BY_TYPE[t] && !('header' in m)) return m as ModuleData;
  const nt = LEGACY_TYPE_MAP[t] ?? (t === 'standard_text' ? 'standard_text' : 'standard_single_left_image');
  const out = emptyModule(nt);
  if ('headline' in out) out.headline = String(m.header ?? '');
  if ('body' in out) out.body = String(m.body ?? '');
  if ('image' in out) out.image = { brief: String(m.image_brief ?? ''), url: '' };
  if (nt === 'standard_tech_specs') { out.specs = String(m.body ?? '').split('\n').filter(Boolean).map((l) => { const [n, ...v] = l.split(':'); return { name: n.trim().slice(0, 30), value: v.join(':').trim() }; }); out.headline = String(m.header ?? ''); }
  return out;
}

/** Text phẳng để diff / đếm / gói bàn giao. */
export function moduleToText(m: ModuleData, idx: number): string {
  const spec = MODULE_BY_TYPE[m.type];
  const lines: string[] = [`[${idx + 1}] ${spec?.amazon_name ?? m.type}`];
  const walk = (fields: FieldSpec[], data: Record<string, unknown>, indent = '') => {
    for (const f of fields) {
      const v = data[f.key];
      if (f.type === 'image') { const im = (v ?? {}) as { brief?: string; url?: string }; if (im.brief || im.url) lines.push(`${indent}${f.label}: ${im.url || ''}${im.brief ? ` (brief: ${im.brief})` : ''}`); }
      else if (f.type === 'list') ((v as Record<string, unknown>[]) ?? []).forEach((it, i) => { lines.push(`${indent}${f.label_item ?? f.label} ${i + 1}:`); walk(f.item, it, indent + '  '); });
      else if (f.type === 'table') ((v as Record<string, string>[]) ?? []).forEach((r) => lines.push(`${indent}${f.cols.map((c) => r[c.key] ?? '').join(' | ')}`));
      else if (v) lines.push(`${indent}${f.label}: ${String(v)}`);
    }
  };
  walk(spec?.fields ?? [], m);
  return lines.join('\n');
}

/** Gói bàn giao Markdown theo đúng thứ tự trường của Seller Central. */
export function handoffMarkdown(asin: string, title: string, modules: ModuleData[], version: number): string {
  const out: string[] = [`# Gói bàn giao A+ — ${asin} · v${version}`, `Sản phẩm: ${title}`, '', `Số module: ${modules.length} (Standard ≤ ${STANDARD_MAX_MODULES}, Premium ≤ ${PREMIUM_MAX_MODULES})`, '', '> Vào Seller Central → Advertising → A+ Content Manager → Start creating A+ content → thêm module theo thứ tự dưới đây. Mỗi trường copy nguyên văn.', ''];
  modules.forEach((m, i) => {
    const spec = MODULE_BY_TYPE[m.type];
    out.push(`## Module ${i + 1}: ${spec?.amazon_name ?? m.type}`);
    if (spec?.note) out.push(`_${spec.note}_`);
    out.push('', moduleToText(m, i).split('\n').slice(1).map((l) => `- ${l}`).join('\n'), '');
  });
  out.push('---', 'Sau khi Amazon duyệt: quay lại Content Studio → bấm **Ghi nhận đã publish** (hệ thống không tự đẩy lên Amazon).');
  return out.join('\n');
}
