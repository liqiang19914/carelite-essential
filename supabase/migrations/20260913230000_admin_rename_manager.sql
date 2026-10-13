-- 平台后台编辑商户名称（及超管显示名）
-- 背景：business_name 仅注册时写入，商户改名（如"韩老师"→"小凯同学"）后平台商户列表、
-- 话术训练看板员工列（取 root profile real_name）仍显示旧名，此前无任何编辑入口。
CREATE OR REPLACE FUNCTION public.admin_rename_manager(
  p_manager_id uuid,
  p_business_name text,
  p_owner_real_name text DEFAULT NULL
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_name  text := btrim(COALESCE(p_business_name, ''));
  v_owner text := btrim(COALESCE(p_owner_real_name, ''));
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '只有平台管理员可以修改商户名称' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_name) < 2 OR char_length(v_name) > 50 THEN
    RAISE EXCEPTION '商户名称需 2-50 个字符' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '商户不存在' USING ERRCODE = '22023';
  END IF;

  UPDATE public.managers
  SET business_name = v_name,
      updated_at = now()
  WHERE id = p_manager_id;

  -- 可选：同步超管（root profile，与 managers 同 id）的显示名。
  -- 传 NULL 表示不改；传空串表示清空（回退到 nickname 展示）。
  IF p_owner_real_name IS NOT NULL THEN
    UPDATE public.profiles
    SET real_name = NULLIF(v_owner, ''),
        updated_at = now()
    WHERE id = p_manager_id
      AND role = 'manager'
      AND parent_manager_id IS NULL;
  END IF;

  RETURN json_build_object('success', true, 'business_name', v_name);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_rename_manager(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_rename_manager(uuid, text, text) TO authenticated, service_role;
