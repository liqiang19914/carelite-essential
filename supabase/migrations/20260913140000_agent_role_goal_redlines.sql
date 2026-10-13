-- ============================================================
-- Task 5: 员工智能体「角色 / 目的 / 红线」可编辑
-- 1) get_manager_knowledge_settings 返回 agent_role/agent_goal/agent_redlines
-- 2) update_manager_knowledge_settings（本人）与
--    update_manager_knowledge_settings_for_manager（代编辑）增加三个可选参数
--    均带 DEFAULT，旧调用方不受影响；新值为 NULL 时不覆盖既有配置
-- 草稿/克隆/发布链路在 20260913100000 迁移中已贯通三字段
-- ============================================================

-- 长度保护（自定义角色为自由文本，故不做枚举约束）
ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_agent_role_len_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_agent_role_len_check
  CHECK (agent_role IS NULL OR length(btrim(agent_role)) BETWEEN 1 AND 50);

-- ── 读取：返回三字段 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_manager_knowledge_settings(p_manager_id uuid DEFAULT NULL::uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_is_admin BOOLEAN;
  v_target UUID;
  v_row RECORD;
  v_doc_count INT;
  v_auto_count INT;
  v_last_train TIMESTAMPTZ;
  v_ready_count INT;
  v_parsing_count INT;
  v_failed_count INT;
  v_indexing_count INT;
  v_uploading_count INT;
  v_authorized BOOLEAN := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  SELECT public.is_admin(v_uid) INTO v_is_admin;

  IF p_manager_id IS NULL THEN
    v_target := v_uid;
    v_authorized := true;
  ELSIF v_is_admin THEN
    v_target := p_manager_id;
    v_authorized := true;
  ELSIF p_manager_id = v_uid THEN
    v_target := v_uid;
    v_authorized := true;
  ELSIF public.has_enterprise_permission('health_managers', v_uid)
        AND public.get_profile_enterprise_id(p_manager_id) IS NOT NULL
        AND public.get_profile_enterprise_id(p_manager_id) = public.get_profile_enterprise_id(v_uid) THEN
    v_target := p_manager_id;
    v_authorized := true;
  ELSIF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_manager_id AND parent_manager_id = v_uid
  ) THEN
    v_target := p_manager_id;
    v_authorized := true;
  END IF;

  IF NOT v_authorized THEN
    RETURN json_build_object('error', '权限不足');
  END IF;

  SELECT m.id, m.knowledge_index_id, m.knowledge_index_status,
         m.knowledge_model, m.knowledge_system_prompt,
         m.agent_role, m.agent_goal, m.agent_redlines
    INTO v_row
    FROM public.managers m
   WHERE m.id = v_target;

  IF NOT FOUND THEN
    RETURN json_build_object('error', '管理师不存在');
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE source = 'user_upload'),
    COUNT(*) FILTER (WHERE source = 'auto_sync'),
    MAX(updated_at) FILTER (WHERE source = 'auto_sync'),
    COUNT(*) FILTER (WHERE status = 'ready'),
    COUNT(*) FILTER (WHERE status = 'parsing'),
    COUNT(*) FILTER (WHERE status = 'failed'),
    COUNT(*) FILTER (WHERE status = 'indexing'),
    COUNT(*) FILTER (WHERE status = 'uploading')
    INTO v_doc_count, v_auto_count, v_last_train,
         v_ready_count, v_parsing_count, v_failed_count, v_indexing_count, v_uploading_count
    FROM public.manager_knowledge_documents
   WHERE manager_id = v_target;

  RETURN json_build_object(
    'manager_id', v_row.id,
    'knowledge_index_id', v_row.knowledge_index_id,
    'knowledge_index_status', COALESCE(v_row.knowledge_index_status, 'none'),
    'knowledge_model', COALESCE(v_row.knowledge_model, 'qwen3.6-plus'),
    'knowledge_system_prompt', v_row.knowledge_system_prompt,
    'agent_role', COALESCE(v_row.agent_role, 'health_manager'),
    'agent_goal', v_row.agent_goal,
    'agent_redlines', v_row.agent_redlines,
    'user_upload_count', COALESCE(v_doc_count, 0),
    'auto_sync_count', COALESCE(v_auto_count, 0),
    'last_train_at', v_last_train,
    'ready_count', COALESCE(v_ready_count, 0),
    'parsing_count', COALESCE(v_parsing_count, 0),
    'failed_count', COALESCE(v_failed_count, 0),
    'indexing_count', COALESCE(v_indexing_count, 0),
    'uploading_count', COALESCE(v_uploading_count, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_manager_knowledge_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_knowledge_settings(uuid) TO authenticated;

-- ── 本人更新 ─────────────────────────────────────────────────
-- 先删旧的两参签名，否则同名重载会让 PostgREST 无法解析 RPC
DROP FUNCTION IF EXISTS public.update_manager_knowledge_settings(text, text);

CREATE OR REPLACE FUNCTION public.update_manager_knowledge_settings(
  p_model text,
  p_system_prompt text,
  p_agent_role text DEFAULT NULL,
  p_agent_goal text DEFAULT NULL,
  p_agent_redlines text DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_is_manager BOOLEAN;
  v_role TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  SELECT EXISTS (SELECT 1 FROM public.managers WHERE id = v_uid) INTO v_is_manager;
  IF NOT v_is_manager THEN
    RETURN json_build_object('error', '仅健康管理师可操作');
  END IF;

  IF p_system_prompt IS NOT NULL AND length(p_system_prompt) > 2000 THEN
    p_system_prompt := substring(p_system_prompt, 1, 2000);
  END IF;

  v_role := NULLIF(btrim(COALESCE(p_agent_role, '')), '');
  IF v_role IS NOT NULL THEN
    IF length(v_role) > 50 THEN
      RETURN json_build_object('error', '角色名称不能超过 50 个字');
    END IF;
    -- health_manager / sales 为预置角色，其它值视为自定义角色自由文本
  END IF;

  UPDATE public.managers
     SET knowledge_model = COALESCE(NULLIF(btrim(p_model), ''), 'qwen3.6-plus'),
         knowledge_system_prompt = NULLIF(btrim(COALESCE(p_system_prompt, '')), ''),
         agent_role = COALESCE(v_role, agent_role),
         agent_goal = CASE WHEN p_agent_goal IS NULL THEN agent_goal
                           ELSE NULLIF(btrim(substring(p_agent_goal, 1, 1000)), '') END,
         agent_redlines = CASE WHEN p_agent_redlines IS NULL THEN agent_redlines
                               ELSE NULLIF(btrim(substring(p_agent_redlines, 1, 1000)), '') END,
         updated_at = NOW()
   WHERE id = v_uid;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_manager_knowledge_settings(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_manager_knowledge_settings(text, text, text, text, text) TO authenticated;

-- ── 代编辑（老板 / 企业管理员） ───────────────────────────────
DROP FUNCTION IF EXISTS public.update_manager_knowledge_settings_for_manager(uuid, text, text);

CREATE OR REPLACE FUNCTION public.update_manager_knowledge_settings_for_manager(
  p_manager_id uuid,
  p_model text,
  p_system_prompt text,
  p_agent_role text DEFAULT NULL,
  p_agent_goal text DEFAULT NULL,
  p_agent_redlines text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_authorized BOOLEAN := false;
  v_role TEXT;
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
    RETURN json_build_object('error', '管理师不存在');
  END IF;

  IF p_system_prompt IS NOT NULL AND length(p_system_prompt) > 2000 THEN
    p_system_prompt := substring(p_system_prompt, 1, 2000);
  END IF;

  v_role := NULLIF(btrim(COALESCE(p_agent_role, '')), '');
  IF v_role IS NOT NULL AND length(v_role) > 50 THEN
    RETURN json_build_object('error', '角色名称不能超过 50 个字');
  END IF;

  UPDATE public.managers
     SET knowledge_model = COALESCE(NULLIF(btrim(p_model), ''), 'qwen3.6-plus'),
         knowledge_system_prompt = NULLIF(btrim(COALESCE(p_system_prompt, '')), ''),
         agent_role = COALESCE(v_role, agent_role),
         agent_goal = CASE WHEN p_agent_goal IS NULL THEN agent_goal
                           ELSE NULLIF(btrim(substring(p_agent_goal, 1, 1000)), '') END,
         agent_redlines = CASE WHEN p_agent_redlines IS NULL THEN agent_redlines
                               ELSE NULLIF(btrim(substring(p_agent_redlines, 1, 1000)), '') END,
         updated_at = NOW()
   WHERE id = p_manager_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_manager_knowledge_settings_for_manager(uuid, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_manager_knowledge_settings_for_manager(uuid, text, text, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
