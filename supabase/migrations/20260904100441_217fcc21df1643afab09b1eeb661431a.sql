-- ============================================================
-- Feature 426：就业关系表 enterprise_employments + 主就业镜像列
-- 幂等增量变更；RLS 启用但零 policy（deny all，仅 SECURITY DEFINER / service_role 可读写）
-- ============================================================

-- 1) enterprise_roles 加 UNIQUE(id, enterprise_id)，供就业表复合外键校验角色属本企业
DO $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'enterprise_roles_id_enterprise_key'
  ) THEN
    ALTER TABLE public.enterprise_roles
      ADD CONSTRAINT enterprise_roles_id_enterprise_key UNIQUE (id, enterprise_id);
  END IF;
END;
$function$;

-- 2) 就业表：一个账号可在多家企业各有一条就业；partial unique 保证同企业不重复在职
CREATE TABLE IF NOT EXISTS public.enterprise_employments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  enterprise_id uuid NOT NULL REFERENCES public.enterprises(id) ON DELETE CASCADE,
  enterprise_role_id uuid,
  supervisor_auth_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  sub_role text NOT NULL DEFAULT 'health_manager',
  permissions jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'disabled', 'left', 'pending')),
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT enterprise_employments_role_enterprise_fkey
    FOREIGN KEY (enterprise_role_id, enterprise_id)
    REFERENCES public.enterprise_roles(id, enterprise_id)
    ON DELETE SET NULL
);

-- 3) 索引
CREATE UNIQUE INDEX IF NOT EXISTS enterprise_employments_active_pair_unique
  ON public.enterprise_employments (auth_user_id, enterprise_id)
  WHERE status IN ('active', 'disabled', 'pending');

CREATE UNIQUE INDEX IF NOT EXISTS enterprise_employments_primary_unique
  ON public.enterprise_employments (auth_user_id)
  WHERE is_primary AND status IN ('active', 'disabled', 'pending');

CREATE INDEX IF NOT EXISTS enterprise_employments_user_status_idx
  ON public.enterprise_employments (auth_user_id, status);

CREATE INDEX IF NOT EXISTS enterprise_employments_enterprise_status_idx
  ON public.enterprise_employments (enterprise_id, status);

CREATE INDEX IF NOT EXISTS enterprise_employments_supervisor_idx
  ON public.enterprise_employments (supervisor_auth_user_id)
  WHERE supervisor_auth_user_id IS NOT NULL;

-- 4) RLS：启用且不开放任何 anon/authenticated 直读直写（全部走 SECURITY DEFINER 或 service_role）
ALTER TABLE public.enterprise_employments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.enterprise_employments FROM anon, authenticated;

-- 5) profiles 主就业镜像列
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS primary_employment_id uuid
  REFERENCES public.enterprise_employments(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS profiles_primary_employment_idx
  ON public.profiles (primary_employment_id)
  WHERE primary_employment_id IS NOT NULL;