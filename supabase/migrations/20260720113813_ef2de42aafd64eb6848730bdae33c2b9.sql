-- 隐私阀门 helper:管理师端 RLS policy 调用它来判断"该客户对该数据类别是否允许被绑定的管理师查看"。
-- SECURITY DEFINER 是因为它会在 RLS 内部被调用,需要绕过 profiles 自身的 RLS(否则会递归)。
-- 只读 profiles.privacy_settings 单一字段,不做任何写入,提权面最小。
-- p_category 允许 4 个白名单键(与 UserPrivacy 页面开关一一对应);
-- 默认值必须与前端 src/services/privacySettings.ts 的 DEFAULT_PRIVACY_SETTINGS 保持一致:全部 true(默认开放)。
-- 非法 category 或 profile 不存在时返回 false = 保守失败(fail-closed)。
CREATE OR REPLACE FUNCTION public.can_manager_view_client_category(
  p_client_id uuid,
  p_category text
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT (p.privacy_settings->>p_category)::boolean
      FROM public.profiles p
      WHERE p.id = p_client_id
    ),
    CASE p_category
      WHEN 'share_records'  THEN true
      WHEN 'share_vitals'   THEN true
      WHEN 'show_phone'     THEN true
      WHEN 'data_analysis'  THEN true
      ELSE false
    END
  );
$$;

COMMENT ON FUNCTION public.can_manager_view_client_category(uuid, text)
IS 'Privacy toggle gate for manager-side reads. Used inside RLS USING(...) clauses. Returns true when the client (p_client_id) allows the given category (share_records / share_vitals / show_phone / data_analysis) to be visible to bound managers. Defaults all 4 categories to true when the profile has no explicit setting, matching frontend DEFAULT_PRIVACY_SETTINGS. Unknown categories fail-closed (false).';

REVOKE ALL ON FUNCTION public.can_manager_view_client_category(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_manager_view_client_category(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_manager_view_client_category(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manager_view_client_category(uuid, text) TO service_role;