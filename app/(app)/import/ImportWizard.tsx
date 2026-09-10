'use client';

import React from 'react';
import { fetchAll } from '@/lib/limits';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { parseCsv, toNumber } from '@/lib/import/csv';
import { SCHEMAS, autoMap, type ImportKind, type ImportSchema, type FieldDef } from '@/lib/import/schemas';
import { Card, CardHeader, Badge, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Parsed = { headers: string[]; rows: string[][]; filename: string };
type RowResult = { row: number; asin: string; message: string };
type Job = { id: string; kind: ImportKind; filename: string | null; rows_total: number; rows_ok: number; rows_failed: number; created_at: string; errors: RowResult[] | null };

export default function ImportWizard() {
  const { tenant, can } = useTenant();
  const canWrite = can('data.import');
  const [kind, setKind] = React.useState<ImportKind>('sales');
  const [parsed, setParsed] = React.useState<Parsed | null>(null);
  const [map, setMap] = React.useState<Record<string, string>>({});
  const [running, setRunning] = React.useState(false);
  const [result, setResult] = React.useState<{ ok: number; failed: number; errors: RowResult[] } | null>(null);
  const [jobs, setJobs] = React.useState<Job[]>([]);
  const schema = SCHEMAS[kind];

  const loadJobs = React.useCallback(async () => {
    if (!tenant) return;
    const { data } = await supabase.from('import_jobs').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(10);
    setJobs((data ?? []) as Job[]);
  }, [tenant]);
  React.useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data fetch on tenant change
    void loadJobs();
  }, [loadJobs]);

  const [dragOver, setDragOver] = React.useState(false);

  function onFile(f: File | undefined) {
    if (!f) return;
    f.text().then((text) => {
      const { headers, rows } = parseCsv(text);
      setParsed({ headers, rows, filename: f.name });
      setMap(autoMap(headers, schema) as Record<string, string>);
      setResult(null);
    });
  }

  // ---- validate + normalise rows ----
  const prepared = React.useMemo(() => {
    if (!parsed) return null;
    const idx = (k: string) => parsed.headers.indexOf(map[k] ?? '');
    const out: { row: number; data: Record<string, unknown>; error?: string }[] = [];
    parsed.rows.forEach((r, i) => {
      const data: Record<string, unknown> = {};
      let error: string | undefined;
      for (const f of schema.fields) {
        const ci = idx(f.key);
        const raw = ci >= 0 ? r[ci]?.trim() : undefined;
        if (!raw) {
          if (f.required) error ??= `Thiếu ${f.label}`;
          continue;
        }
        if (f.type === 'text') data[f.key] = f.key === 'asin' ? raw.toUpperCase() : raw;
        else if (f.type === 'date') {
          const d = new Date(raw);
          if (isNaN(d.getTime())) error ??= `${f.label} không hợp lệ: "${raw}"`; else data[f.key] = d.toISOString().slice(0, 10);
        } else {
          const n = toNumber(raw);
          if (n == null) error ??= `${f.label} không phải số: "${raw}"`;
          else if (n < 0) error ??= `${f.label} âm`;
          else data[f.key] = f.type === 'int' ? Math.round(n) : n;
        }
      }
      if (!error && typeof data.asin === 'string' && !/^[A-Z0-9]{10}$/.test(data.asin)) error = `ASIN không hợp lệ: ${data.asin}`;
      out.push({ row: i + 2, data, error });
    });
    return out;
  }, [parsed, map, schema]);

  const validCount = prepared?.filter((p) => !p.error).length ?? 0;
  const invalidCount = (prepared?.length ?? 0) - validCount;
  const missingRequired = schema.fields.filter((f) => f.required && !map[f.key]);

  // ---- import ----
  async function run() {
    if (!tenant || !prepared) return;
    setRunning(true);
    const errors: RowResult[] = prepared.filter((p) => p.error).map((p) => ({ row: p.row, asin: String(p.data.asin ?? ''), message: p.error! }));
    const valid = prepared.filter((p) => !p.error);
    let ok = 0;

    // map asin → sku id (cho các loại update)
    const existing = await fetchAll<{ id: string; asin: string }>((from, to) => supabase.from('amazon_skus').select('id, asin').eq('tenant_id', tenant.id).order('id').range(from, to));
    const byAsin = new Map(existing.map((s) => [s.asin as string, s.id as string]));

    if (schema.daily) {
      // ---- Gộp theo ngày + ASIN ----
      type Agg = { units: number; revenue: number; ad_spend: number; ad_sales: number; ad_clicks: number; ad_impressions: number };
      const agg = new Map<string, Agg>();
      const days = new Set<string>();
      let skipped = 0;
      for (const p of valid) {
        const st = String(p.data.order_status ?? '').toLowerCase();
        if (kind === 'orders' && (st.includes('cancel') || st.includes('huỷ') || st.includes('huy'))) { skipped++; continue; }
        const asin = String(p.data.asin);
        const date = String(p.data.date);
        if (!byAsin.has(asin)) { errors.push({ row: p.row, asin, message: 'ASIN chưa có trong danh mục – bỏ qua' }); continue; }
        days.add(date);
        const key = `${asin}|${date}`;
        const a = agg.get(key) ?? { units: 0, revenue: 0, ad_spend: 0, ad_sales: 0, ad_clicks: 0, ad_impressions: 0 };
        if (kind === 'orders') { a.units += Number(p.data.quantity ?? 0); a.revenue += Number(p.data.item_price ?? 0); }
        else { a.ad_spend += Number(p.data.ad_spend ?? 0); a.ad_sales += Number(p.data.ad_sales ?? 0); a.ad_clicks += Number(p.data.ad_clicks ?? 0); a.ad_impressions += Number(p.data.ad_impressions ?? 0); }
        agg.set(key, a);
      }
      // Với đơn hàng: ASIN trong danh mục không có đơn ngày đó → 0 (để velocity đúng)
      const rows: Record<string, unknown>[] = [];
      const dayList = [...days].sort();
      if (kind === 'orders') {
        for (const [asin, id] of byAsin) for (const date of dayList) {
          const a = agg.get(`${asin}|${date}`);
          rows.push({ sku_id: id, date, tenant_id: tenant.id, asin, units: a?.units ?? 0, revenue: a ? Math.round(a.revenue * 100) / 100 : 0, sources: { orders: 'csv' } });
        }
      } else {
        for (const [key, a] of agg) {
          const [asin, date] = key.split('|');
          rows.push({ sku_id: byAsin.get(asin), date, tenant_id: tenant.id, asin, ad_spend: Math.round(a.ad_spend * 100) / 100, ad_sales: Math.round(a.ad_sales * 100) / 100, ad_clicks: a.ad_clicks, ad_impressions: a.ad_impressions, sources: { ads: 'csv' } });
        }
      }
      for (let i = 0; i < rows.length; i += 500) {
        const chunk = rows.slice(i, i + 500);
        const { error } = await supabase.from('sku_daily_snapshots').upsert(chunk, { onConflict: 'sku_id,date' });
        if (error) { errors.push({ row: 0, asin: '', message: error.message }); break; }
        ok += chunk.length;
      }
      if (kind === 'orders') await supabase.rpc('refresh_sku_rolling_from_snapshots', { t: tenant.id });
      await supabase.from('import_jobs').insert({
        tenant_id: tenant.id, kind, filename: parsed?.filename, rows_total: prepared.length, rows_ok: ok, rows_failed: errors.length,
        errors: errors.slice(0, 200), column_map: { ...map, _days: dayList.length, _skipped_cancelled: skipped },
      });
      setResult({ ok, failed: errors.length, errors });
      setRunning(false);
      loadJobs();
      return;
    }

    const CHUNK = 200;
    for (let i = 0; i < valid.length; i += CHUNK) {
      const chunk = valid.slice(i, i + CHUNK);
      if (kind === 'catalog') {
        const payload = chunk.map((p) => ({ tenant_id: tenant.id, marketplace: tenant.marketplace, ...p.data }));
        const { error } = await supabase.from('amazon_skus').upsert(payload, { onConflict: 'tenant_id,asin,marketplace' });
        if (error) chunk.forEach((p) => errors.push({ row: p.row, asin: String(p.data.asin), message: error.message })); else ok += chunk.length;
      } else if (kind === 'reviews') {
        const rows = chunk.filter((p) => byAsin.has(String(p.data.asin)));
        chunk.filter((p) => !byAsin.has(String(p.data.asin))).forEach((p) => errors.push({ row: p.row, asin: String(p.data.asin), message: 'ASIN chưa có trong danh mục – import Danh mục trước' }));
        if (rows.length) {
          const yes = (v: unknown) => ['yes', 'true', '1', 'y', 'verified', 'có', 'co'].includes(String(v ?? '').trim().toLowerCase());
          const payload = rows.map((p) => ({ tenant_id: tenant.id, asin: String(p.data.asin), rating: p.data.rating, title: p.data.title ?? null, body: p.data.body,
            reviewed_at: p.data.reviewed_at ?? null, reviewer_id: p.data.reviewer_id ?? null, verified_purchase: yes(p.data.verified_purchase), source: 'csv' }));
          const { error } = await supabase.from('raw_reviews').insert(payload);
          if (error) rows.forEach((p) => errors.push({ row: p.row, asin: String(p.data.asin), message: error.message })); else ok += rows.length;
        }
      } else if (kind === 'cogs') {
        const rows = chunk.filter((p) => byAsin.has(String(p.data.asin)));
        chunk.filter((p) => !byAsin.has(String(p.data.asin))).forEach((p) => errors.push({ row: p.row, asin: String(p.data.asin), message: 'ASIN chưa có trong danh mục – import Danh mục trước' }));
        if (rows.length) {
          const payload = rows.map((p) => ({ tenant_id: tenant.id, sku_id: byAsin.get(String(p.data.asin)), source: 'csv',
            effective_from: p.data.effective_from ?? new Date().toISOString().slice(0, 10), cogs: p.data.cogs, landed_cost: p.data.landed_cost ?? null, note: p.data.note ?? null }));
          const { error } = await supabase.from('cogs_history').upsert(payload, { onConflict: 'sku_id,effective_from' });
          if (error) rows.forEach((p) => errors.push({ row: p.row, asin: String(p.data.asin), message: error.message })); else ok += rows.length;
        }
      } else {
        // sales / inventory / fees: update từng SKU
        const stamp = new Date().toISOString();
        const results = await Promise.all(chunk.map(async (p) => {
          const id = byAsin.get(String(p.data.asin));
          if (!id) return { p, err: 'ASIN chưa có trong danh mục – import Danh mục trước' };
          const { asin: _a, sku: _s, ...rest } = p.data as Record<string, unknown>;
          void _a; void _s;
          const patch: Record<string, unknown> = { ...rest, last_ingested_at: stamp };
          if (kind === 'fees') { patch.fee_source = 'csv'; patch.fee_updated_at = stamp; }
          const { error } = await supabase.from('amazon_skus').update(patch).eq('id', id);
          return { p, err: error?.message };
        }));
        results.forEach(({ p, err }) => { if (err) errors.push({ row: p.row, asin: String(p.data.asin), message: err }); else ok++; });
      }
    }

    await supabase.from('import_jobs').insert({
      tenant_id: tenant.id, kind, filename: parsed?.filename, rows_total: prepared.length, rows_ok: ok, rows_failed: errors.length,
      errors: errors.slice(0, 200), column_map: map,
    });
    setResult({ ok, failed: errors.length, errors });
    setRunning(false);
    loadJobs();
  }

  if (!tenant) return <Spinner />;
  if (!canWrite) return <ErrorBox message="Vai trò của bạn không có quyền nhập dữ liệu (data.import)." />;

  return (
    <div className="grid lg:grid-cols-3 gap-6">
      <div className="lg:col-span-2 space-y-6">
        {/* Step 1 */}
        <Card>
          <CardHeader title="1. Chọn loại dữ liệu" />
          <div className="p-5 grid sm:grid-cols-2 gap-2">
            {(Object.values(SCHEMAS) as ImportSchema[]).map((s) => {
              const needCogs = s.kind === 'cogs' && !can('cogs.write');
              return (
              <button key={s.kind} disabled={needCogs} title={needCogs ? 'Chỉ Finance/Owner (cogs.write) được nhập giá vốn' : ''} onClick={() => { setKind(s.kind); setParsed(null); setResult(null); }}
                className={`text-left p-3 rounded-lg border transition disabled:opacity-50 disabled:cursor-not-allowed ${kind === s.kind ? 'border-indigo-600 bg-indigo-50' : 'border-gray-200 hover:bg-gray-50'}`}>
                <p className="font-medium text-gray-900">{s.title}{needCogs && <span className="ml-2 text-xs font-normal text-gray-500">🔒 Finance</span>}</p>
                <p className="text-xs text-gray-500 mt-0.5">{s.description}</p>
              </button>
              );
            })}
          </div>
          <div className="px-5 pb-5 text-sm text-gray-600">
            <p><b>Nguồn:</b> {schema.source}</p>
            <p className="mt-1"><a href={schema.templateFile} download className="text-indigo-600 hover:underline">Tải file mẫu</a> · Cột bắt buộc: {schema.fields.filter((f) => f.required).map((f) => f.label).join(', ')}</p>
          </div>
        </Card>

        {/* Step 2 */}
        <Card>
          <CardHeader title="2. Chọn file & khớp cột" subtitle="Hệ thống tự đoán cột theo tên trong export của Seller Central; bạn có thể sửa." />
          <div className="p-5 space-y-4">
            <label
              onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
              onDragLeave={() => setDragOver(false)}
              onDrop={(e) => { e.preventDefault(); setDragOver(false); onFile(e.dataTransfer.files?.[0]); }}
              className={`flex flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed px-6 py-8 text-center cursor-pointer transition-colors ${dragOver ? 'border-slate-900 bg-slate-50' : parsed ? 'border-emerald-300 bg-emerald-50/40' : 'border-gray-300 bg-gray-50 hover:border-slate-400 hover:bg-white'}`}
            >
              <input type="file" accept=".csv,.txt,.tsv" className="sr-only" onChange={(e) => { onFile(e.target.files?.[0]); e.target.value = ''; }} />
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" className={parsed ? 'text-emerald-600' : 'text-gray-400'} aria-hidden>
                {parsed
                  ? <><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6" /><path d="m9 15 2 2 4-4" /></>
                  : <><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="m17 8-5-5-5 5" /><path d="M12 3v12" /></>}
              </svg>
              {parsed ? (
                <>
                  <p className="text-sm font-medium text-gray-900">{parsed.filename}</p>
                  <p className="text-xs text-gray-600">{parsed.rows.length} dòng · {parsed.headers.length} cột · <span className="underline">chọn file khác</span></p>
                </>
              ) : (
                <>
                  <p className="text-sm font-medium text-gray-900">Kéo thả file CSV vào đây</p>
                  <p className="text-xs text-gray-500">hoặc</p>
                  <span className={btn.secondary}>Chọn file từ máy</span>
                  <p className="text-xs text-gray-500 mt-1">Hỗ trợ .csv, .tsv, .txt (export từ Seller Central)</p>
                </>
              )}
            </label>
            {parsed && (
              <>
                <div className="grid sm:grid-cols-2 gap-3">
                  {schema.fields.map((f) => <MapRow key={f.key} f={f} headers={parsed.headers} value={map[f.key] ?? ''} onChange={(v) => setMap({ ...map, [f.key]: v })} />)}
                </div>
                {missingRequired.length > 0 && <ErrorBox message={`Chưa khớp cột bắt buộc: ${missingRequired.map((f) => f.label).join(', ')}`} />}
                <Preview prepared={prepared!} schema={schema} />
              </>
            )}
          </div>
        </Card>

        {/* Step 3 */}
        {parsed && (
          <Card>
            <CardHeader title="3. Nhập" />
            <div className="p-5 flex flex-wrap items-center gap-4">
              <div className="text-sm">
                <span className="text-emerald-700 font-medium">{validCount} hợp lệ</span>
                {invalidCount > 0 && <span className="text-red-600 font-medium"> · {invalidCount} lỗi (sẽ bỏ qua)</span>}
              </div>
              <button className={btn.primary} disabled={running || validCount === 0 || missingRequired.length > 0} onClick={run}>
                {running ? 'Đang nhập…' : `Nhập ${validCount} dòng`}
              </button>
              {result && (
                <div className="w-full mt-2 rounded-lg bg-gray-50 border border-gray-200 p-4 text-sm">
                  <p className="font-medium text-gray-900">Kết quả: {result.ok} {schema.daily ? 'bản ghi ngày×ASIN' : 'dòng'} thành công · {result.failed} lỗi</p>
                  {result.errors.length > 0 && (
                    <ul className="mt-2 max-h-48 overflow-auto text-xs text-red-700 space-y-0.5">
                      {result.errors.slice(0, 50).map((e, i) => <li key={i}>Dòng {e.row} {e.asin && <span className="font-mono">{e.asin}</span>}: {e.message}</li>)}
                    </ul>
                  )}
                  <p className="mt-2"><Link href="/" className="text-indigo-600 hover:underline">Xem Tổng quan →</Link></p>
                </div>
              )}
            </div>
          </Card>
        )}
      </div>

      {/* History */}
      <Card className="self-start">
        <CardHeader title="Lịch sử nhập" subtitle="10 lần gần nhất" />
        {jobs.length === 0 ? <p className="p-5 text-sm text-gray-500">Chưa có lần nhập nào.</p> : (
          <ul className="divide-y divide-gray-100">
            {jobs.map((j) => (
              <li key={j.id} className="px-5 py-3 text-sm">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium text-gray-900">{SCHEMAS[j.kind]?.title ?? j.kind}</span>
                  <span className="text-xs text-gray-400">{new Date(j.created_at).toLocaleString('vi-VN')}</span>
                </div>
                <p className="text-xs text-gray-500 truncate">{j.filename}</p>
                <div className="mt-1 flex gap-2">
                  <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-600/20">{j.rows_ok} ok</Badge>
                  {j.rows_failed > 0 && <Badge className="bg-red-50 text-red-700 ring-red-600/20">{j.rows_failed} lỗi</Badge>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function MapRow({ f, headers, value, onChange }: { f: FieldDef; headers: string[]; value: string; onChange: (v: string) => void }) {
  return (
    <div>
      <label className="block text-xs font-medium text-gray-700 mb-1">{f.label}{f.required && <span className="text-red-500"> *</span>}</label>
      <select value={value} onChange={(e) => onChange(e.target.value)} className={`${input} ${!value && f.required ? 'border-red-300' : ''}`}>
        <option value="">— bỏ qua —</option>
        {headers.map((h) => <option key={h} value={h}>{h}</option>)}
      </select>
      {f.hint && <p className="text-[11px] text-gray-500 mt-0.5">{f.hint}</p>}
    </div>
  );
}

function Preview({ prepared, schema }: { prepared: { row: number; data: Record<string, unknown>; error?: string }[]; schema: ImportSchema }) {
  const sample = prepared.slice(0, 8);
  return (
    <div className="overflow-x-auto rounded-lg border border-gray-200">
      <table className="w-full text-xs">
        <thead className="bg-gray-50 text-gray-500">
          <tr><th className="px-2 py-1.5 text-left">#</th>{schema.fields.map((f) => <th key={f.key} className="px-2 py-1.5 text-left">{f.label}</th>)}<th className="px-2 py-1.5 text-left">Kiểm tra</th></tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {sample.map((p) => (
            <tr key={p.row} className={p.error ? 'bg-red-50/60' : ''}>
              <td className="px-2 py-1.5 text-gray-400">{p.row}</td>
              {schema.fields.map((f) => <td key={f.key} className="px-2 py-1.5 font-mono">{p.data[f.key] == null ? <span className="text-gray-300">—</span> : String(p.data[f.key])}</td>)}
              <td className="px-2 py-1.5">{p.error ? <span className="text-red-600">{p.error}</span> : <span className="text-emerald-600">✓</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {prepared.length > sample.length && <p className="px-2 py-1.5 text-[11px] text-gray-500 bg-gray-50">… và {prepared.length - sample.length} dòng nữa</p>}
    </div>
  );
}
