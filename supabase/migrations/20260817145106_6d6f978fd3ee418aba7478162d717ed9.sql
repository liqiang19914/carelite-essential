-- ============================================================
-- Feature 132 问答入口升级
-- 管理员可代配任意健管师的公开问答配置（同企业 RBAC）
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_public_qa_config_for_manager(
  p_manager_id uuid,
  p_enabled boolean,
  p_welcome_message text,
  p_lead_capture_mode text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_authorized boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;

  IF p_manager_id = v_uid THEN
    v_authorized := true;
  ELSIF public.is_admin(v_uid) THEN
    v_authorized := true;
  ELSIF public.has_enterprise_permission('health_managers', v_uid)
        AND public.get_profile_enterprise_id(p_manager_id) IS NOT NULL
        AND public.get_profile_enterprise_id(p_manager_id) = public.get_profile_enterprise_id(v_uid) THEN
    v_authorized := true;
  ELSIF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_manager_id AND parent_manager_id = v_uid
  ) THEN
    v_authorized := true;
  END IF;

  IF NOT v_authorized THEN
    RETURN json_build_object('error', '权限不足');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RETURN json_build_object('error', '健管师不存在');
  END IF;

  IF p_lead_capture_mode IS NULL
     OR p_lead_capture_mode NOT IN ('none','card_after_3_turns','ai_natural','both') THEN
    RETURN json_build_object('error', '无效的留资策略');
  END IF;

  UPDATE public.managers
     SET public_qa_enabled = COALESCE(p_enabled, false),
         public_qa_welcome_message = NULLIF(trim(COALESCE(p_welcome_message, '')), ''),
         public_qa_lead_capture_mode = p_lead_capture_mode,
         updated_at = NOW()
   WHERE id = p_manager_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_public_qa_config_for_manager(uuid, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_public_qa_config_for_manager(uuid, boolean, text, text) TO authenticated;