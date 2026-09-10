'use client';

import React from 'react';
import { supabase } from '@/lib/supabase/client';

export type Role = 'owner' | 'operator' | 'viewer';
export type Tenant = { id: string; slug: string; name: string; marketplace: string; role: Role };

type Ctx = {
  user: { id: string; email: string } | null;
  tenants: Tenant[];
  tenant: Tenant | null;
  setTenantId: (id: string) => void;
  loading: boolean;
  /** Người dùng có được thao tác ghi (operator/owner)? */
  canWrite: boolean;
  /** Có đủ cấp để duyệt gợi ý cấp `lvl`? L2 → owner; L0/L1 → operator+ */
  canApprove: (lvl: string) => boolean;
};

const TenantContext = React.createContext<Ctx | null>(null);
const STORAGE_KEY = 'vexim.tenant';

export function TenantProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = React.useState<Ctx['user']>(null);
  const [tenants, setTenants] = React.useState<Tenant[]>([]);
  const [tenantId, setTenantIdState] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);

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
  const role = tenant?.role;
  const canWrite = role === 'owner' || role === 'operator';
  const canApprove = React.useCallback(
    (lvl: string) => (lvl === 'L2' ? role === 'owner' : role === 'owner' || role === 'operator'),
    [role]
  );

  return (
    <TenantContext.Provider value={{ user, tenants, tenant, setTenantId, loading, canWrite, canApprove }}>
      {children}
    </TenantContext.Provider>
  );
}

export function useTenant(): Ctx {
  const ctx = React.useContext(TenantContext);
  if (!ctx) throw new Error('useTenant must be used inside <TenantProvider>');
  return ctx;
}

export const ROLE_LABEL: Record<Role, string> = { owner: 'Owner', operator: 'Operator', viewer: 'Viewer' };
