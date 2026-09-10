'use client';

import React from 'react';
import { APLUS_MODULES, MODULE_BY_TYPE, STANDARD_MAX_MODULES, PREMIUM_MAX_MODULES, emptyModule, upgradeLegacyModule, type FieldSpec, type ModuleData } from '@/lib/aplus';
import { btn, input } from '@/components/ui';

type Fact = { id: string; key: string; value: string; unit: string | null };
type Img = { brief?: string; url?: string };

const cnt = (s: unknown, max: number) => { const n = String(s ?? '').length; return <span className={`text-[10px] tabular-nums ${n > max ? 'text-red-600 font-semibold' : 'text-gray-400'}`}>{n}/{max}</span>; };

/** Editor A+ theo đúng cấu trúc module Amazon. Dữ liệu: {modules: ModuleData[]} */
export default function AplusEditor({ modules, onChange, facts, premium }: { modules: ModuleData[]; onChange: (m: ModuleData[]) => void; facts: Fact[]; premium: boolean }) {
  const mods = React.useMemo(() => modules.map((m) => upgradeLegacyModule(m as Record<string, unknown>)), [modules]);
  const max = premium ? PREMIUM_MAX_MODULES : STANDARD_MAX_MODULES;
  const [open, setOpen] = React.useState<number | null>(mods.length ? 0 : null);
  const [insertFact, setInsertFact] = React.useState<string>('');

  const set = (i: number, m: ModuleData) => { const n = [...mods]; n[i] = m; onChange(n); };
  const move = (i: number, d: -1 | 1) => { const j = i + d; if (j < 0 || j >= mods.length) return; const n = [...mods]; [n[i], n[j]] = [n[j], n[i]]; onChange(n); setOpen(j); };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2 text-xs text-gray-600">
        <span className={mods.length > max ? 'text-red-600 font-semibold' : ''}>{mods.length}/{max} module ({premium ? 'Premium' : 'Standard'} A+)</span>
        <span>·</span>
        <label className="flex items-center gap-1">Chèn fact vào ô đang gõ:
          <select value={insertFact} onChange={(e) => setInsertFact(e.target.value)} className={`${input} w-56 py-0.5 text-xs`}>
            <option value="">— fact đã xác minh —</option>
            {facts.map((f) => <option key={f.id} value={`{fact:${f.key}}`}>{f.key}: {f.value}{f.unit ? ` ${f.unit}` : ''}</option>)}
          </select>
        </label>
        {insertFact && <span className="font-mono bg-gray-100 px-1 rounded">{insertFact}</span>}
        <span className="text-gray-400">(placeholder sẽ được điền khi lưu/kiểm tra gate; số liệu chỉ từ fact đã xác minh)</span>
      </div>

      {mods.map((m, i) => {
        const spec = MODULE_BY_TYPE[m.type];
        return (
          <div key={i} className="border border-gray-200 bg-white rounded-md">
            <div className="flex items-center gap-2 px-3 py-2 bg-gray-50 rounded-t-md">
              <button className="text-xs text-gray-500 w-5" onClick={() => setOpen(open === i ? null : i)}>{open === i ? '▾' : '▸'}</button>
              <span className="text-xs text-gray-500 w-6">{i + 1}.</span>
              <select value={m.type} onChange={(e) => set(i, emptyModule(e.target.value))} className={`${input} flex-1 py-1 text-sm`}>
                {APLUS_MODULES.filter((s) => premium || !s.premium).map((s) => <option key={s.type} value={s.type}>{s.amazon_name} — {s.name}</option>)}
              </select>
              <button className={btn.ghost} onClick={() => move(i, -1)} title="Lên">↑</button>
              <button className={btn.ghost} onClick={() => move(i, 1)} title="Xuống">↓</button>
              <button className={btn.ghost} onClick={() => { onChange(mods.filter((_, j) => j !== i)); setOpen(null); }}>✕</button>
            </div>
            {open === i && spec && (
              <div className="p-3 space-y-2">
                {spec.note && <p className="text-xs text-amber-700">{spec.note}</p>}
                <Fields fields={spec.fields} data={m} onChange={(d) => set(i, { ...d, type: m.type })} insertFact={insertFact} />
              </div>
            )}
          </div>
        );
      })}
      {mods.length < max && (
        <button className={btn.secondary} onClick={() => { onChange([...mods, emptyModule('standard_single_left_image')]); setOpen(mods.length); }}>+ Module</button>
      )}
    </div>
  );
}

function Fields({ fields, data, onChange, insertFact }: { fields: FieldSpec[]; data: Record<string, unknown>; onChange: (d: Record<string, unknown>) => void; insertFact: string }) {
  const up = (k: string, v: unknown) => onChange({ ...data, [k]: v });
  const withFact = (e: React.MouseEvent<HTMLElement>, k: string, cur: string) => { if (insertFact && e.altKey) { up(k, `${cur}${cur && !cur.endsWith(' ') ? ' ' : ''}${insertFact}`); } };
  return (
    <div className="grid gap-2 sm:grid-cols-2">
      {fields.map((f) => {
        if (f.type === 'text' || f.type === 'textarea') {
          const v = String(data[f.key] ?? '');
          const wide = f.type === 'textarea';
          return (
            <label key={f.key} className={`text-xs text-gray-600 ${wide ? 'sm:col-span-2' : ''}`}>
              <span className="flex justify-between">{f.label}{f.required && <span className="text-red-500">*</span>} {cnt(v, f.max)}</span>
              {wide
                ? <textarea value={v} onChange={(e) => up(f.key, e.target.value)} onClick={(e) => withFact(e, f.key, v)} className={`${input} h-20 text-sm`} placeholder={f.factable ? 'Alt+click để chèn fact đã chọn' : ''} />
                : <input value={v} onChange={(e) => up(f.key, e.target.value)} onClick={(e) => withFact(e, f.key, v)} className={`${input} text-sm`} />}
            </label>
          );
        }
        if (f.type === 'image') {
          const im = (data[f.key] as Img) ?? {};
          return (
            <div key={f.key} className="text-xs text-gray-600 sm:col-span-2 rounded border border-dashed border-gray-300 p-2 grid gap-1 sm:grid-cols-2">
              <span className="sm:col-span-2">{f.label}{f.required && <span className="text-red-500">*</span>} <span className="text-gray-400">— tối thiểu {f.minW}×{f.minH} px, JPG/PNG, không chữ chồng lên sản phẩm</span></span>
              <input value={im.brief ?? ''} onChange={(e) => up(f.key, { ...im, brief: e.target.value })} className={`${input} text-sm`} placeholder="Image brief cho designer (bố cục, nội dung, cảm xúc)" />
              <input value={im.url ?? ''} onChange={(e) => up(f.key, { ...im, url: e.target.value })} className={`${input} text-sm`} placeholder="URL/tên file ảnh đã duyệt (nếu có)" />
            </div>
          );
        }
        if (f.type === 'list') {
          const items = (data[f.key] as Record<string, unknown>[]) ?? [];
          return (
            <div key={f.key} className="sm:col-span-2 space-y-2">
              <p className="text-xs font-medium text-gray-700">{f.label} <span className="text-gray-400">({items.length}/{f.count})</span></p>
              {items.map((it, j) => (
                <div key={j} className="rounded border border-gray-200 p-2">
                  <div className="flex justify-between text-xs text-gray-500 mb-1"><span>{f.label_item ?? 'Mục'} {j + 1}</span><button className="text-gray-400 hover:text-red-600" onClick={() => up(f.key, items.filter((_, x) => x !== j))}>✕</button></div>
                  <Fields fields={f.item} data={it} onChange={(d) => { const n = [...items]; n[j] = d; up(f.key, n); }} insertFact={insertFact} />
                </div>
              ))}
              {items.length < f.count && <button className={btn.ghost} onClick={() => up(f.key, [...items, Object.fromEntries(f.item.map((i) => [i.key, i.type === 'image' ? { brief: '', url: '' } : '']))])}>+ {f.label_item ?? 'Mục'}</button>}
            </div>
          );
        }
        if (f.type === 'table') {
          const rows = (data[f.key] as Record<string, string>[]) ?? [];
          return (
            <div key={f.key} className="sm:col-span-2">
              <p className="text-xs font-medium text-gray-700 mb-1">{f.label} <span className="text-gray-400">({rows.length}/{f.maxRows})</span></p>
              <table className="w-full text-sm">
                <thead><tr className="text-xs text-gray-500">{f.cols.map((c) => <th key={c.key} className="text-left font-normal pb-1">{c.label}</th>)}<th /></tr></thead>
                <tbody>
                  {rows.map((r, j) => (
                    <tr key={j}>
                      {f.cols.map((c) => <td key={c.key} className="pr-2 pb-1"><input value={r[c.key] ?? ''} onChange={(e) => { const n = [...rows]; n[j] = { ...r, [c.key]: e.target.value }; up(f.key, n); }} className={`${input} text-sm`} />{cnt(r[c.key], c.max)}</td>)}
                      <td><button className="text-gray-400 hover:text-red-600" onClick={() => up(f.key, rows.filter((_, x) => x !== j))}>✕</button></td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {rows.length < f.maxRows && <button className={btn.ghost} onClick={() => up(f.key, [...rows, Object.fromEntries(f.cols.map((c) => [c.key, '']))])}>+ Dòng</button>}
            </div>
          );
        }
        return null;
      })}
    </div>
  );
}

// ---------- Preview bố cục gần giống Amazon ----------
function Ph({ w, h, label }: { w: number; h: number; label?: string }) {
  return <div className="bg-gray-100 border border-gray-200 text-[10px] text-gray-400 flex items-center justify-center text-center p-1" style={{ aspectRatio: `${w}/${h}`, width: '100%' }}>{label || `${w}×${h}`}</div>;
}
function T({ s, cls = '' }: { s: unknown; cls?: string }) { return s ? <p className={`whitespace-pre-wrap ${cls}`}>{String(s)}</p> : null; }
function img(v: unknown, w: number, h: number) {
  const im = (v as Img) ?? {};
  // eslint-disable-next-line @next/next/no-img-element -- preview ảnh ngoài, không tối ưu
  return im.url ? <img src={im.url} alt="" className="w-full object-cover" style={{ aspectRatio: `${w}/${h}` }} /> : <Ph w={w} h={h} label={im.brief || undefined} />;
}
export function AplusPreview({ modules, mobile }: { modules: ModuleData[]; mobile: boolean }) {
  const mods = modules.map((m) => upgradeLegacyModule(m as Record<string, unknown>));
  return (
    <div className={`mx-auto bg-white border border-gray-200 rounded-lg p-4 space-y-6 text-gray-800 ${mobile ? 'max-w-[390px] text-[13px]' : 'max-w-[970px] text-sm'}`}>
      <p className="text-[11px] uppercase tracking-wide text-gray-400">From the brand</p>
      {mods.map((m, i) => {
        const spec = MODULE_BY_TYPE[m.type];
        const blocks = (m.blocks as Record<string, unknown>[]) ?? [];
        return (
          <div key={i} className="space-y-2">
            <p className="text-[10px] text-indigo-400">{spec?.amazon_name}</p>
            {m.type === 'standard_company_logo' && <div className="w-[300px]">{img(m.image, 600, 180)}</div>}
            {m.type === 'standard_image_header_text' && <>{img(m.image, 970, 600)}<T s={m.headline} cls="text-xl font-semibold" /><T s={m.subheadline} cls="font-medium" /><T s={m.body} /></>}
            {(m.type === 'standard_text' || m.type === 'standard_product_description_text') && <><T s={m.headline} cls="text-lg font-semibold" /><T s={m.body} /></>}
            {(m.type === 'standard_single_left_image' || m.type === 'standard_single_right_image') && (
              <div className={`grid gap-4 ${mobile ? '' : 'grid-cols-3'}`}>
                <div className={m.type === 'standard_single_right_image' && !mobile ? 'order-2' : ''}>{img(m.image, 300, 300)}</div>
                <div className={mobile ? '' : 'col-span-2'}><T s={m.headline} cls="text-lg font-semibold" /><T s={m.body} /></div>
              </div>)}
            {m.type === 'standard_single_image_highlights' && (
              <div className={`grid gap-4 ${mobile ? '' : 'grid-cols-3'}`}>
                <div>{img(m.image, 300, 300)}</div>
                <div className={mobile ? '' : 'col-span-2'}><T s={m.headline} cls="text-lg font-semibold" /><T s={m.subheadline} cls="font-medium" /><T s={m.body} />
                  <ul className="list-disc pl-5">{((m.highlights as { text: string }[]) ?? []).filter((h) => h.text).map((h, j) => <li key={j}>{h.text}</li>)}</ul></div>
              </div>)}
            {m.type === 'standard_single_image_sidebar' && (
              <div className={`grid gap-4 ${mobile ? '' : 'grid-cols-4'}`}>
                <div>{img(m.image, 300, 400)}</div>
                <div className={mobile ? '' : 'col-span-2'}><T s={m.headline} cls="text-lg font-semibold" /><T s={m.body} /></div>
                <div className="bg-gray-50 p-2 rounded">{img(m.sidebar_image, 350, 175)}<T s={m.sidebar_headline} cls="font-medium mt-1" /><T s={m.sidebar_body} cls="text-xs" /></div>
              </div>)}
            {m.type === 'standard_single_image_specs_detail' && (
              <div className={`grid gap-4 ${mobile ? '' : 'grid-cols-3'}`}>
                <div>{img(m.image, 300, 300)}</div>
                <div><T s={m.headline} cls="text-lg font-semibold" /><T s={m.body} /></div>
                <table className="text-xs"><tbody>{((m.specs as { name: string; value: string }[]) ?? []).map((r, j) => <tr key={j} className="border-b"><td className="font-medium pr-2 py-1">{r.name}</td><td className="py-1">{r.value}</td></tr>)}</tbody></table>
              </div>)}
            {(m.type === 'standard_three_image_text' || m.type === 'standard_four_image_text' || m.type === 'standard_four_image_text_quadrant' || m.type === 'standard_multiple_image_module_a') && (
              <>
                <T s={m.headline} cls="text-lg font-semibold" />
                <div className={`grid gap-3 ${mobile ? 'grid-cols-2' : m.type === 'standard_three_image_text' ? 'grid-cols-3' : m.type === 'standard_four_image_text_quadrant' ? 'grid-cols-2' : 'grid-cols-4'}`}>
                  {blocks.map((b, j) => <div key={j}>{img(b.image, 300, 300)}<T s={b.caption} cls="text-[11px] text-gray-500" /><T s={b.headline} cls="font-medium mt-1" /><T s={b.body} cls="text-xs" /></div>)}
                </div>
              </>)}
            {m.type === 'standard_image_text_overlay' && (
              <div className="relative">{img(m.image, 970, 300)}<div className={`absolute inset-0 flex flex-col justify-center p-6 ${m.overlay === 'dark' ? 'text-white' : 'text-gray-900'}`}><T s={m.headline} cls="text-xl font-semibold" /><T s={m.body} /></div></div>)}
            {m.type === 'standard_comparison_chart' && (
              <table className="w-full text-xs border-collapse">
                <thead><tr><th /> {((m.products as Record<string, unknown>[]) ?? []).map((p, j) => <th key={j} className="p-1 align-bottom"><div className="w-16 mx-auto">{img(p.image, 150, 300)}</div><div className="font-medium">{String(p.title ?? '')}</div><div className="text-gray-400">{String(p.asin ?? '')}</div></th>)}</tr></thead>
                <tbody>{((m.metrics as { name: string; values: string }[]) ?? []).map((r, j) => <tr key={j} className="border-t"><td className="font-medium p-1">{r.name}</td>{(r.values ?? '').split('|').map((v, k) => <td key={k} className="p-1 text-center">{v.trim()}</td>)}</tr>)}</tbody>
              </table>)}
            {m.type === 'standard_tech_specs' && (
              <><T s={m.headline} cls="text-lg font-semibold" /><table className="w-full text-xs"><tbody>{((m.specs as { name: string; value: string }[]) ?? []).map((r, j) => <tr key={j} className="border-b"><td className="font-medium pr-2 py-1 w-1/3 bg-gray-50">{r.name}</td><td className="py-1 px-2">{r.value}</td></tr>)}</tbody></table></>)}
            {m.type === 'premium_full_image' && <div className="relative">{img(m.image, 1464, 600)}<div className="absolute bottom-4 left-4 text-white drop-shadow"><T s={m.headline} cls="text-2xl font-semibold" /><T s={m.body} /></div></div>}
          </div>
        );
      })}
    </div>
  );
}
