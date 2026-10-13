-- 我的可见商户范围：本人 + 企业内相关员工。
-- 算法与商户端称重列表里的 caller_members 完全一致，这里抽出来给 RLS 复用。
CREATE OR REPLACE FUNCTION public.oem_scope_manager_ids()
RETURNS TABLE (manager_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH caller AS (
    SELECT p.id, p.parent_manager_id, p.sub_role, p.role::text AS role,
           COALESCE(p.is_disabled, false) AS disabled
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid())
  )
  SELECT m.id
  FROM caller c
  JOIN public.profiles m ON m.role::text = 'manager'
  WHERE c.role = 'manager'
    AND c.disabled = false
    AND (
      (c.parent_manager_id IS NULL AND (m.id = c.id OR m.parent_manager_id = c.id))
      OR (c.sub_role = 'admin' AND c.parent_manager_id IS NOT NULL
          AND (m.id = c.parent_manager_id OR m.parent_manager_id = c.parent_manager_id))
      OR (c.parent_manager_id IS NOT NULL AND COALESCE(c.sub_role, '') <> 'admin' AND m.id = c.id)
    );
$$;

-- 客户是否还开着体征共享。客户关掉后谁都看不到，这条承诺不因为「数据是我产出的」而放宽。
CREATE OR REPLACE FUNCTION public.record_vitals_shared(p_record_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.health_records hr
    WHERE hr.id = p_record_id
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
  );
$$;

-- 这条数据的商户章是否落在我的范围内
CREATE OR REPLACE FUNCTION public.oem_stamp_in_my_scope(p_oem_manager_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_oem_manager_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.oem_scope_manager_ids() s WHERE s.manager_id = p_oem_manager_id);
$$;

REVOKE EXECUTE ON FUNCTION public.oem_scope_manager_ids() FROM anon;
REVOKE EXECUTE ON FUNCTION public.oem_stamp_in_my_scope(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.record_vitals_shared(uuid) FROM anon;