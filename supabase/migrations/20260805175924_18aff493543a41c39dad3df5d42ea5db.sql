-- 商户内容中心：企业资格判定 + RLS + 列级授权

-- 1. 商户侧资格：调用者是未禁用的管理师，且其企业根已通过认证且未禁用
CREATE OR REPLACE FUNCTION public.is_active_enterprise_content_member(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles caller
    JOIN public.managers root_manager
      ON root_manager.id = public.get_enterprise_root_manager_id(uid)
    JOIN public.profiles root_profile
      ON root_profile.id = root_manager.id
    WHERE caller.id = uid
      AND caller.role = 'manager'
      AND COALESCE(caller.is_disabled, false) = false
      AND root_manager.certification_status = 'approved'
      AND COALESCE(root_profile.is_disabled, false) = false
  );
$$;

REVOKE ALL ON FUNCTION public.is_active_enterprise_content_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_active_enterprise_content_member(uuid) TO authenticated;

-- 2. 公开侧资格：企业根本身可对外露出内容。仅供 SECURITY DEFINER 函数内部调用。
CREATE OR REPLACE FUNCTION public.is_public_enterprise_content_root(
  p_root_manager_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.managers m
    JOIN public.profiles p ON p.id = m.id
    WHERE m.id = p_root_manager_id
      AND m.certification_status = 'approved'
      AND COALESCE(p.is_disabled, false) = false
  );
$$;

REVOKE ALL ON FUNCTION public.is_public_enterprise_content_root(uuid)
  FROM PUBLIC, anon, authenticated;

-- 3. RLS
ALTER TABLE public.manager_content_spaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manager_content_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manager_content_album_pages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_content_spaces_enterprise_all
  ON public.manager_content_spaces;
CREATE POLICY manager_content_spaces_enterprise_all
ON public.manager_content_spaces
FOR ALL
TO authenticated
USING (
  public.is_admin(auth.uid())
  OR (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
)
WITH CHECK (
  public.is_admin(auth.uid())
  OR (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
);

DROP POLICY IF EXISTS manager_content_items_enterprise_all
  ON public.manager_content_items;
CREATE POLICY manager_content_items_enterprise_all
ON public.manager_content_items
FOR ALL
TO authenticated
USING (
  public.is_admin(auth.uid())
  OR (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
)
WITH CHECK (
  public.is_admin(auth.uid())
  OR (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
);

DROP POLICY IF EXISTS manager_content_album_pages_enterprise_all
  ON public.manager_content_album_pages;
CREATE POLICY manager_content_album_pages_enterprise_all
ON public.manager_content_album_pages
FOR ALL
TO authenticated
USING (
  public.is_admin(auth.uid())
  OR (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
)
WITH CHECK (
  public.is_admin(auth.uid())
  OR (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
);

-- 4. 匿名一律无表级权限：客户只能走两个 SECURITY DEFINER 公开读取函数
REVOKE ALL ON public.manager_content_spaces FROM anon;
REVOKE ALL ON public.manager_content_items FROM anon;
REVOKE ALL ON public.manager_content_album_pages FROM anon;

-- 5. 列级授权：机检列与人工痕迹列一律不给前端写，只能经 RPC / service_role 变更
REVOKE ALL ON public.manager_content_spaces FROM authenticated;
GRANT SELECT ON public.manager_content_spaces TO authenticated;

REVOKE ALL ON public.manager_content_items FROM authenticated;
GRANT SELECT, DELETE ON public.manager_content_items TO authenticated;
GRANT INSERT (
  root_manager_id,
  content_type,
  title,
  cover_url,
  cover_storage_key,
  article_doc,
  sort_weight
) ON public.manager_content_items TO authenticated;
GRANT UPDATE (
  title,
  cover_url,
  cover_storage_key,
  article_doc,
  sort_weight
) ON public.manager_content_items TO authenticated;

REVOKE ALL ON public.manager_content_album_pages FROM authenticated;
GRANT SELECT, DELETE ON public.manager_content_album_pages TO authenticated;
GRANT INSERT (
  content_id,
  root_manager_id,
  sort_order,
  image_url,
  image_storage_key,
  alt_text
) ON public.manager_content_album_pages TO authenticated;
GRANT UPDATE (
  sort_order,
  image_url,
  image_storage_key,
  alt_text
) ON public.manager_content_album_pages TO authenticated;