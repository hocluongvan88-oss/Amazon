'use client';

import React from 'react';
import { fetchAll } from '@/lib/limits';
import Link from 'next/link';
import { supabase } from '@/lib/supabase/client';
import { useTenant } from '@/lib/tenant';
import { parseCsv, toNumber } from '@/lib/import/csv';
import { SCHEMAS, SERVER_KINDS, autoMap, type ImportKind, type ImportSchema, type FieldDef } from '@/lib/import/schemas';
import { Card, CardHeader, Badge, Spinner, ErrorBox, btn, input } from '@/components/ui';

type Parsed = { headers: string[]; rows: string[][]; filename: string };
type RowResult = { row: number; asin: string; message: string };
type Job = { id: string; kind: ImportKind; filename: string | null; rows_total: number; rows_ok: number; rows_failed: number; created_at: string; errors: RowResult[] | null };
type Batch = { id: string; import_kind: ImportKind; filename: string | null; status: string; rows_total: number; rows_valid: number; rows_invalid: number; rows_inserted: number; rows_updated: number; rows_skipped: number; rows_error: number; created_at: string; committed_at: string | null };
type DryRun = {
  batch_id: string; feed_key: string; schema_version: number; rows_total: number; rows_valid: number; rows_invalid: number;
  date_min: string | null; date_max: string | null; distinct_asins: number; unknown_asins: string[]; unknown_asin_count: number;
  duplicate_rows_in_file: number; existing_days_in_range: number; errors: { row: number; error: string }[]; can_commit: boolean;
};
type CommitResult = {
  ok: boolean; status: string; run_id: string; rows_inserted: number; rows_updated: number; rows_skipped: number; rows_error: number; rows_invalid: number;
  window_start: string | null; window_end: string | null; errors: { row: number; error: string }[];
};

async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export default function ImportWizard() {
  const { tenant, can } = useTenant();
  const canWrite = can('data.import');
  const [kind, setKind] = React.useState<ImportKind>('sales');
  const [parsed, setParsed] = React.useState<Parsed | null>(null);
  const [map, setMap] = React.useState<Record<string, string>>({});
  const [running, setRunning] = React.useState(false);
  const [result, setResult] = React.useState<{ ok: number; failed: number; errors: RowResult[] } | null>(null);
  const [jobs, setJobs] = React.useState<Job[]>([]);
  const [batches, setBatches] = React.useState<Batch[]>([]);
  const [rawText, setRawText] = React.useState<string>('');
  const [dry, setDry] = React.useState<DryRun | null>(null);
  const [commit, setCommit] = React.useState<CommitResult | null>(null);
  const [srvError, setSrvError] = React.useState<string | null>(null);
  const [progress, setProgress] = React.useState<string>('');
  const schema = SCHEMAS[kind];
  const serverSide = SERVER_KINDS.has(kind);

  const loadJobs = React.useCallback(async () => {
    if (!tenant) return;
    const [{ data }, { data: b }] = await Promise.all([
      supabase.from('import_jobs').select('*').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(10),
      supabase.from('ingest_batches').select('id, import_kind, filename, status, rows_total, rows_valid, rows_invalid, rows_inserted, rows_updated, rows_skipped, rows_error, created_at, committed_at').eq('tenant_id', tenant.id).order('created_at', { ascending: false }).limit(10),
    ]);
    setJobs((data ?? []) as Job[]);
    setBatches((b ?? []) as Batch[]);
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
      setRawText(text);
      setMap(autoMap(headers, schema) as Record<string, string>);
      setResult(null); setDry(null); setCommit(null); setSrvError(null);
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
        if (f.type === 'text' || f.type === 'list' || f.type === 'percent') data[f.key] = f.key === 'asin' ? raw.toUpperCase() : raw;
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

  // ---- Feed server-side (021): dòng thô → ingest_open/add_rows/dry_run/commit ----
  const rawRows = React.useMemo(() => {
    if (!parsed || !serverSide) return [];
    const idx = (k: string) => parsed.headers.indexOf(map[k] ?? '');
    return parsed.rows.map((r) => {
      const o: Record<string, string> = {};
      for (const f of schema.fields) { const ci = idx(f.key); const v = ci >= 0 ? r[ci] : undefined; if (v != null && v.trim() !== '') o[f.key] = v.trim(); }
      return o;
    });
  }, [parsed, map, schema, serverSide]);

  async function runDryRun() {
    if (!tenant || !parsed) return;
    setRunning(true); setSrvError(null); setCommit(null); setDry(null);
    try {
      setProgress('Mở phiên nhập…');
      const fileHash = await sha256Hex(`${kind}\n${rawText}`);
      const { data: opened, error: e1 } = await supabase.rpc('ingest_open', { p_tenant: tenant.id, p_kind: kind, p_filename: parsed.filename, p_file_hash: fileHash, p_column_map: map });
      if (e1) throw new Error(e1.message);
      const op = opened as { batch_id: string; duplicate: boolean; committed_at?: string; rows_inserted?: number; rows_updated?: number; rows_skipped?: number };
      if (op.duplicate) {
        setSrvError(`File này đã được ghi lúc ${op.committed_at ? new Date(op.committed_at).toLocaleString('vi-VN') : '?'} (${op.rows_inserted ?? 0} thêm · ${op.rows_updated ?? 0} cập nhật · ${op.rows_skipped ?? 0} trùng). Không ghi lại.`);
        return;
      }
      const CHUNK = 1000;
      for (let i = 0; i < rawRows.length; i += CHUNK) {
        setProgress(`Kiểm tra dòng ${i + 1}–${Math.min(i + CHUNK, rawRows.length)} / ${rawRows.length}…`);
        const { error: e2 } = await supabase.rpc('ingest_add_rows', { p_batch: op.batch_id, p_rows: rawRows.slice(i, i + CHUNK), p_offset: i + 1 });
        if (e2) throw new Error(e2.message);
      }
      setProgress('Tổng hợp kết quả kiểm tra…');
      const { data: d, error: e3 } = await supabase.rpc('ingest_dry_run', { p_batch: op.batch_id });
      if (e3) throw new Error(e3.message);
      setDry(d as DryRun);
    } catch (err) {
      setSrvError(err instanceof Error ? err.message : String(err));
    } finally { setRunning(false); setProgress(''); }
  }

  async function runCommit() {
    if (!dry) return;
    setRunning(true); setSrvError(null);
    try {
      setProgress('Đang ghi vào hệ thống…');
      const { data, error } = await supabase.rpc('ingest_commit', { p_batch: dry.batch_id });
      if (error) throw new Error(error.message);
      setCommit(data as CommitResult);
      setDry(null);
      loadJobs();
    } catch (err) {
      setSrvError(err instanceof Error ? err.message : String(err));
    } finally { setRunning(false); setProgress(''); }
  }

  // ---- import (feed cũ, ghi trực tiếp — sẽ chuyển sang RPC ở bước sau) ----
  async function run() {
    if (!tenant || !prepared) return;
    setRunning(true);
    const errors: RowResult[] = prepared.filter((p) => p.error).map((p) => ({ row: p.row, asin: String(p.data.asin ?? ''), message: p.error! }));
    const valid = prepared.filter((p) => !p.error);
    let ok = 0;

    // map asin → sku id (cho các loại update)
    const existing = await fetchAll<{ id: string; asin: string }>((from, to) => supabase.from('amazon_skus').select('id, asin').eq('tenant_id', tenant.id).order('id').range(from, to));
    const byAsin = new Map(existing.map((s) => [s.asin as string, s.id as string]));

    if (serverSide) { setRunning(false); return; }

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
          <div className="p-5 space-y-4">
            {([['daily', 'Vận hành theo ngày'], ['ads', 'Quảng cáo'], ['catalog', 'Danh mục & tham số SKU'], ['other', 'Khác']] as const).map(([g, label]) => (
              <div key={g}>
                <p className="text-xs font-semibold uppercase tracking-wide text-gray-500 mb-2">{label}</p>
                <div className="grid sm:grid-cols-2 gap-2">
                  {(Object.values(SCHEMAS) as ImportSchema[]).filter((s) => s.group === g).map((s) => {
                    const needCogs = s.kind === 'cogs' && !can('cogs.write');
                    return (
                      <button key={s.kind} disabled={needCogs} title={needCogs ? 'Chỉ Finance/Owner (cogs.write) được nhập giá vốn' : ''} onClick={() => { setKind(s.kind); setParsed(null); setResult(null); setDry(null); setCommit(null); setSrvError(null); }}
                        className={`text-left p-3 rounded-lg border transition disabled:opacity-50 disabled:cursor-not-allowed ${kind === s.kind ? 'border-indigo-600 bg-indigo-50' : 'border-gray-200 hover:bg-gray-50'}`}>
                        <p className="font-medium text-gray-900">{s.title}{needCogs && <span className="ml-2 text-xs font-normal text-gray-500">🔒 Finance</span>}
                          {SERVER_KINDS.has(s.kind) && <span className="ml-2 text-[10px] font-medium text-emerald-700 bg-emerald-50 ring-1 ring-emerald-600/20 rounded px-1.5 py-0.5 align-middle">kiểm tra trước khi ghi</span>}
                        </p>
                        <p className="text-xs text-gray-500 mt-0.5">{s.description}</p>
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
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
                  {schema.fields.map((f) => <MapRow key={f.key} f={f} headers={parsed.headers} value={map[f.key] ?? ''} onChange={(v) => { setMap({ ...map, [f.key]: v }); setDry(null); setCommit(null); }} />)}
                </div>
                {missingRequired.length > 0 && <ErrorBox message={`Chưa khớp cột bắt buộc: ${missingRequired.map((f) => f.label).join(', ')}`} />}
                <Preview prepared={prepared!} schema={schema} />
                {serverSide && <p className="text-[11px] text-gray-500">Bảng trên chỉ xem trước khớp cột. Kiểm tra chính thức (định dạng, ngày, ASIN, trùng lặp) do máy chủ thực hiện ở bước 3.</p>}
              </>
            )}
          </div>
        </Card>

        {/* Step 3 — server-side: dry-run → commit */}
        {parsed && serverSide && (
          <Card>
            <CardHeader title="3. Kiểm tra rồi ghi" subtitle="Máy chủ kiểm tra từng dòng theo hợp đồng dữ liệu (cùng chuẩn với API). Bước kiểm tra KHÔNG ghi gì; bạn xem kết quả rồi mới ghi." />
            <div className="p-5 space-y-4 text-sm">
              <div className="flex flex-wrap items-center gap-3">
                <button className={btn.secondary} disabled={running || missingRequired.length > 0 || rawRows.length === 0} onClick={runDryRun}>
                  {running && !dry ? (progress || 'Đang kiểm tra…') : `Kiểm tra ${rawRows.length} dòng (không ghi)`}
                </button>
                {dry && (
                  <button className={btn.primary} disabled={running || !dry.can_commit} onClick={runCommit}>
                    {running ? (progress || 'Đang ghi…') : `Ghi ${dry.rows_valid} dòng hợp lệ`}
                  </button>
                )}
              </div>
              {srvError && <ErrorBox message={srvError} />}
              {dry && (
                <div className="rounded-lg border border-gray-200 bg-gray-50 p-4 space-y-2">
                  <p className="font-medium text-gray-900">Kết quả kiểm tra · feed <span className="font-mono">{dry.feed_key}</span> · schema v{dry.schema_version}</p>
                  <div className="grid sm:grid-cols-3 gap-2 text-xs">
                    <Stat label="Hợp lệ" value={dry.rows_valid} tone="ok" />
                    <Stat label="Lỗi (sẽ bỏ qua)" value={dry.rows_invalid} tone={dry.rows_invalid ? 'bad' : 'muted'} />
                    <Stat label="ASIN khác nhau" value={dry.distinct_asins} />
                    <Stat label="Khoảng ngày" value={dry.date_min ? `${dry.date_min} → ${dry.date_max}` : '—'} />
                    <Stat label="Ngày đã có dữ liệu" value={dry.existing_days_in_range} tone={dry.existing_days_in_range ? 'warn' : 'muted'} hint={dry.existing_days_in_range ? 'Dòng trùng khoá sẽ được cập nhật (restatement); dòng giống hệt bị bỏ qua.' : undefined} />
                    <Stat label="Dòng trùng trong file" value={dry.duplicate_rows_in_file} tone={dry.duplicate_rows_in_file ? 'warn' : 'muted'} />
                  </div>
                  {dry.unknown_asin_count > 0 && (
                    <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1.5">
                      {dry.unknown_asin_count} ASIN chưa có trong Danh mục: <span className="font-mono">{dry.unknown_asins.slice(0, 8).join(', ')}{dry.unknown_asin_count > 8 ? '…' : ''}</span>. Dữ liệu vẫn được lưu vào bảng chuẩn nhưng sẽ không lên dashboard cho tới khi nhập Danh mục.
                    </p>
                  )}
                  {dry.errors.length > 0 && (
                    <ul className="max-h-48 overflow-auto text-xs text-red-700 space-y-0.5">
                      {dry.errors.slice(0, 100).map((e, i) => <li key={i}>Dòng {e.row + 1}: {e.error}</li>)}
                    </ul>
                  )}
                  {!dry.can_commit && <p className="text-xs text-red-700">Không có dòng hợp lệ — sửa file hoặc khớp lại cột.</p>}
                </div>
              )}
              {commit && (
                <div className={`rounded-lg border p-4 ${commit.ok ? 'border-emerald-200 bg-emerald-50/50' : 'border-red-200 bg-red-50/50'}`}>
                  <p className="font-medium text-gray-900">
                    {commit.status === 'succeeded' ? 'Đã ghi thành công' : commit.status === 'partial' ? 'Đã ghi một phần' : 'Ghi thất bại'} · {commit.rows_inserted} thêm · {commit.rows_updated} cập nhật · {commit.rows_skipped} trùng (bỏ qua) · {commit.rows_error + commit.rows_invalid} lỗi
                  </p>
                  {commit.window_start && <p className="text-xs text-gray-600 mt-1">Khoảng ngày {commit.window_start} → {commit.window_end} · run <span className="font-mono">{commit.run_id.slice(0, 8)}</span></p>}
                  {commit.errors.length > 0 && (
                    <ul className="mt-2 max-h-40 overflow-auto text-xs text-red-700 space-y-0.5">
                      {commit.errors.slice(0, 50).map((e, i) => <li key={i}>Dòng {e.row + 1}: {e.error}</li>)}
                    </ul>
                  )}
                  <p className="mt-2 text-xs"><Link href="/" className="text-indigo-600 hover:underline">Xem Tổng quan →</Link> · <Link href="/settings/data-sources" className="text-indigo-600 hover:underline">Độ tươi dữ liệu →</Link></p>
                </div>
              )}
            </div>
          </Card>
        )}

        {/* Step 3 — feed cũ */}
        {parsed && !serverSide && (
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
        <CardHeader title="Lịch sử nhập" subtitle="10 lần gần nhất mỗi loại" />
        {batches.length > 0 && (
          <ul className="divide-y divide-gray-100 border-b border-gray-100">
            {batches.map((b) => (
              <li key={b.id} className="px-5 py-3 text-sm">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium text-gray-900">{SCHEMAS[b.import_kind]?.title ?? b.import_kind}</span>
                  <span className="text-xs text-gray-400">{new Date(b.created_at).toLocaleString('vi-VN')}</span>
                </div>
                <p className="text-xs text-gray-500 truncate">{b.filename}</p>
                <div className="mt-1 flex flex-wrap gap-1.5">
                  <Badge className={b.status === 'committed' ? 'bg-emerald-50 text-emerald-700 ring-emerald-600/20' : b.status === 'failed' ? 'bg-red-50 text-red-700 ring-red-600/20' : 'bg-gray-100 text-gray-600 ring-gray-500/20'}>
                    {b.status === 'committed' ? 'đã ghi' : b.status === 'failed' ? 'thất bại' : b.status === 'validated' ? 'đã kiểm tra, chưa ghi' : 'đang mở'}
                  </Badge>
                  {b.status === 'committed' && <Badge className="bg-gray-50 text-gray-600 ring-gray-500/20">{b.rows_inserted}+ · {b.rows_updated}↻ · {b.rows_skipped}=</Badge>}
                  {(b.rows_invalid + b.rows_error) > 0 && <Badge className="bg-red-50 text-red-700 ring-red-600/20">{b.rows_invalid + b.rows_error} lỗi</Badge>}
                </div>
              </li>
            ))}
          </ul>
        )}
        {jobs.length === 0 && batches.length === 0 ? <p className="p-5 text-sm text-gray-500">Chưa có lần nhập nào.</p> : (
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

function Stat({ label, value, tone, hint }: { label: string; value: number | string; tone?: 'ok' | 'bad' | 'warn' | 'muted'; hint?: string }) {
  const color = tone === 'ok' ? 'text-emerald-700' : tone === 'bad' ? 'text-red-700' : tone === 'warn' ? 'text-amber-700' : tone === 'muted' ? 'text-gray-400' : 'text-gray-900';
  return (
    <div className="rounded border border-gray-200 bg-white px-2.5 py-1.5" title={hint}>
      <p className="text-[10px] uppercase tracking-wide text-gray-500">{label}</p>
      <p className={`font-semibold ${color}`}>{value}</p>
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
