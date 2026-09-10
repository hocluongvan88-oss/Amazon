/** CSV parser nhỏ: hỗ trợ dấu ngoặc kép, dấu phẩy/chấm phẩy/tab, BOM, CRLF. */
export function parseCsv(text: string): { headers: string[]; rows: string[][] } {
  const src = text.replace(/^\uFEFF/, '');
  const firstLine = src.split(/\r?\n/, 1)[0] ?? '';
  const delim = [',', ';', '\t'].map((d) => ({ d, n: firstLine.split(d).length })).sort((a, b) => b.n - a.n)[0].d;

  const out: string[][] = [];
  let row: string[] = [], cell = '', q = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (q) {
      if (c === '"') { if (src[i + 1] === '"') { cell += '"'; i++; } else q = false; }
      else cell += c;
    } else if (c === '"') q = true;
    else if (c === delim) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++;
      row.push(cell); cell = '';
      if (row.some((x) => x.trim() !== '')) out.push(row);
      row = [];
    } else cell += c;
  }
  row.push(cell);
  if (row.some((x) => x.trim() !== '')) out.push(row);

  const headers = (out.shift() ?? []).map((h) => h.trim());
  return { headers, rows: out };
}

/** "1,234.50" | "$12.3" | "12,5" (vi) → number */
export function toNumber(v: string | undefined | null): number | null {
  if (v == null) return null;
  let s = String(v).trim().replace(/[$€£\s%]/g, '');
  if (!s || s === '-' || s.toLowerCase() === 'n/a') return null;
  // 1.234,56 (EU) vs 1,234.56 (US)
  if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(s)) s = s.replace(/\./g, '').replace(',', '.');
  else s = s.replace(/,/g, '');
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export function normalizeHeader(h: string) {
  return h.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}
