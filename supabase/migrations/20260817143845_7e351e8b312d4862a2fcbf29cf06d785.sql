-- ============================================================
-- Feature 131 知识库训练升级
-- 1) manager_knowledge_documents 加企业归属 + 三档可见范围 + 批量分发 + 创建人
-- 2) 知识库设置 RPC 授权升级为企业 RBAC（同企业 + 健管师管理权限）
-- ============================================================

ALTER TABLE public.manager_knowledge_documents
  ADD COLUMN IF NOT EXISTS enterprise_id uuid REFERENCES public.enterprises(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'own_customers'
    CHECK (visibility IN ('all_customers', 'own_customers', 'internal')),
  ADD COLUMN IF NOT EXISTS batch_group_id uuid,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS mkd_enterprise_visibility_idx
  ON public.manager_knowledge_documents (enterprise_id, manager_id, visibility);

-- 回填企业归属
UPDATE public.manager_knowledge_documents d
   SET enterprise_id = m.enterprise_id
  FROM public.managers m
 WHERE m.id = d.manager_id
   AND d.enterprise_id IS NULL;

-- get_manager_knowledge_settings 授权扩展：同企业 + 健管师管理权限可读
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
         m.knowledge_model, m.knowledge_system_prompt
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

-- update_manager_knowledge_settings_for_manager 授权扩展：同企业 + 健管师管理权限可写
CREATE OR REPLACE FUNCTION public.update_manager_knowledge_settings_for_manager(
  p_manager_id uuid,
  p_model text,
  p_system_prompt text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_authorized BOOLEAN := false;
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

  UPDATE public.managers
     SET knowledge_model = COALESCE(NULLIF(trim(p_model), ''), 'qwen3.6-plus'),
         knowledge_system_prompt = NULLIF(trim(COALESCE(p_system_prompt, '')), ''),
         updated_at = NOW()
   WHERE id = p_manager_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_manager_knowledge_settings_for_manager(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_manager_knowledge_settings_for_manager(uuid, text, text) TO authenticated;