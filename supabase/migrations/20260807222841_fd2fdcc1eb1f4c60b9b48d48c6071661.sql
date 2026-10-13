-- ============================================================
-- 企业员工创建链路修复（数据库侧）
-- 1) handle_new_user 幂等化：允许「已有客户档案、后补登录账号」这条路径
--    （原本是裸 INSERT，指定 id 建号时会撞主键，导致建号整体失败）
-- 2) 新增按手机号在 auth.users 精确查号的函数，替代 EF 里
--    listUsers(perPage:200) 的分页扫描（现有 307 个账号，会漏查）
-- 3) 客户归属查询索引
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.profiles (id, phone, nickname)
  VALUES (
    NEW.id,
    NEW.phone,
    COALESCE(NEW.raw_user_meta_data->>'nickname', '用户' || SUBSTR(NEW.phone::text, -4))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$function$;


-- 只给 service_role：仅供边缘函数做手机号查重，不对前端开放
CREATE OR REPLACE FUNCTION public.admin_find_auth_user_by_phones(p_phones text[])
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT u.id
  FROM auth.users u
  WHERE u.phone IS NOT NULL
    AND u.phone = ANY(p_phones)
  ORDER BY u.created_at
  LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.admin_find_auth_user_by_phones(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_find_auth_user_by_phones(text[]) FROM anon;
REVOKE ALL ON FUNCTION public.admin_find_auth_user_by_phones(text[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_find_auth_user_by_phones(text[]) TO service_role;

-- 「这个人是不是本企业的客户」的高频查询路径
CREATE INDEX IF NOT EXISTS idx_client_relations_client_status
  ON public.client_relations (client_id, status);