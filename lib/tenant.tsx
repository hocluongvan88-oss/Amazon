'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';

export type Role = 'owner' | 'ops_lead' | 'operator' | 'finance' | 'content_qa' | 'brand_approver' | 'viewer';
export type Permission = string; // 'domain.action' — xem supabase/012_permissions.sql
export type Tenant = { id: string; slug: string; name: string; marketplace: string; role: Role };

type Ctx = {
  user: { id: string; email: string } | null;
  tenants: Tenant[];
  tenant: Tenant | null;
  setTenantId: (id: string) => void;
  loading: boolean;
  /** Permission hiệu lực trong tenant hiện tại (role + uỷ quyền còn hạn) — từ RPC my_permissions */
  permissions: Set<Permission>;
  /** Kiểm tra permission theo hành động ('rec.create', 'cogs.write', …) */
  can: (perm: Permission) => boolean;
  /** Tương thích: có quyền ghi vận hành (rec.create) */
  canWrite: boolean;
  /** Có đủ cấp để duyệt cấp `tier`? L2 → rec.approve_l2; L1 → rec.approve_l1; L0 → rec.approve_l0 */
  canApprove: (tier: string) => boolean;
};

const TenantContext = React.createContext<Ctx | null>(null);
const STORAGE_KEY = 'vexim.tenant';

export function TenantProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = React.useState<Ctx['user']>(null);
  const [tenants, setTenants] = React.useState<Tenant[]>([]);
  const [tenantId, setTenantIdState] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [permissions, setPermissions] = React.useState<Set<Permission>>(new Set());

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data: { user: u } } = await supabase.auth.getUser();
      if (cancelled) return;
      if (!u) { setLoading(false); return; }
      setUser({ id: u.id, email: u.email ?? '' });

      const { data } = await supabase
        .from('tenant_members')
        .select('role, tenants(id, slug, name, marketplace)')
        .eq('user_id', u.id);
      if (cancelled) return;
      type Row = { role: Role; tenants: { id: string; slug: string; name: string; marketplace: string } | null };
      const list: Tenant[] = ((data ?? []) as unknown as Row[])
        .filter((r) => r.tenants)
        .map((r) => ({ ...r.tenants!, role: r.role }))
        .sort((a, b) => a.name.localeCompare(b.name));
      setTenants(list);
      const saved = typeof window !== 'undefined' ? window.localStorage.getItem(STORAGE_KEY) : null;
      setTenantIdState(list.find((t) => t.id === saved)?.id ?? list[0]?.id ?? null);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, []);

  const setTenantId = React.useCallback((id: string) => {
    setTenantIdState(id);
    window.localStorage.setItem(STORAGE_KEY, id);
  }, []);

  const tenant = tenants.find((t) => t.id === tenantId) ?? null;

  // Permission từ DB (nguồn sự thật); nếu RPC chưa có (chưa chạy 012) → fallback theo role cũ
  React.useEffect(() => {
    let cancelled = false;
    if (!tenant) { return; }
    (async () => {
      const { data, error } = await supabase.rpc('my_permissions', { t: tenant.id });
      if (cancelled) return;
      if (error || !data) { setPermissions(new Set(LEGACY_PERMS[tenant.role] ?? [])); return; }
      setPermissions(new Set((data as string[]) ?? []));
    })();
    return () => { cancelled = true; };
  }, [tenant]);

  const can = React.useCallback((perm: Permission) => permissions.has(perm), [permissions]);
  const canWrite = permissions.has('rec.create');
  const canApprove = React.useCallback(
    (tier: string) => permissions.has(tier === 'L2' ? 'rec.approve_l2' : tier === 'L1' ? 'rec.approve_l1' : 'rec.approve_l0'),
    [permissions]
  );

  return (
    <TenantContext.Provider value={{ user, tenants, tenant, setTenantId, loading, permissions, can, canWrite, canApprove }}>
      {children}
    </TenantContext.Provider>
  );
}

export function useTenant(): Ctx {
  const ctx = React.useContext(TenantContext);
  if (!ctx) throw new Error('useTenant must be used inside <TenantProvider>');
  return ctx;
}

export const ROLE_LABEL: Record<Role, string> = {
  owner: 'Owner', ops_lead: 'Ops Lead', operator: 'Operator', finance: 'Finance',
  content_qa: 'Content / QA', brand_approver: 'Brand Approver', viewer: 'Viewer',
};
export const ROLE_DESC: Record<Role, string> = {
  owner: 'Mọi quyền; duyệt L2; chính sách; ký báo cáo pilot',
  ops_lead: 'Điều phối vận hành; duyệt L1; QA content; duyệt phản hồi khách',
  operator: 'Nhập dữ liệu, xử lý exception, tạo khuyến nghị/draft, duyệt L0, thực thi',
  finance: 'Sở hữu COGS / landed cost / phí; chạy đối soát',
  content_qa: 'Product Facts, listing/A+ draft, compliance gate, triage VoC',
  brand_approver: 'Người của brand: duyệt cuối & publish content, duyệt phản hồi khách',
  viewer: 'Chỉ xem',
};

/** Fallback khi DB chưa có RPC my_permissions (chưa chạy 012). */
const LEGACY_PERMS: Record<string, string[]> = {
  owner: ['dashboard.view','member.manage','policy.edit','sku.write','sku.delete','data.import','cogs.write','rec.create','rec.approve_l0','rec.approve_l1','rec.approve_l2','exception.resolve','action.dry_run','action.execute','action.rollback','voc.triage','voc.approve_response','report.sign'],
  operator: ['dashboard.view','sku.write','data.import','cogs.write','rec.create','rec.approve_l0','rec.approve_l1','exception.resolve','action.dry_run','action.execute','action.rollback','voc.triage','voc.approve_response'],
  viewer: ['dashboard.view'],
};
