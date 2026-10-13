-- 更新 get_manager_knowledge_settings + get_public_qa_config：
-- 各自暴露 5 个文档状态计数（ready/parsing/failed/indexing/uploading），
-- 让前端可从"每文档态"派生"部分可用/训练中/已可用/训练失败/未训练"5 态。

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
  ELSE
    IF EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = p_manager_id AND parent_manager_id = v_uid
    ) THEN
      v_target := p_manager_id;
      v_authorized := true;
    END IF;
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


-- 公开问答配置：anon 可读；加 ready_doc_count 供前端 gate 用（≥1 即允许开公开问答）
CREATE OR REPLACE FUNCTION public.get_public_qa_config(p_manager_id UUID)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manager RECORD;
  v_ready_count INT;
  v_parsing_count INT;
  v_failed_count INT;
  v_total_count INT;
BEGIN
  SELECT
    m.id,
    m.public_qa_enabled,
    m.public_qa_welcome_message,
    m.public_qa_lead_capture_mode,
    m.tagline,
    m.partner_card_display_name,
    m.avatar_url,
    m.knowledge_index_status,
    p.public_card_is_example
    INTO v_manager
    FROM public.managers m
    LEFT JOIN public.profiles p ON p.id = m.id
   WHERE m.id = p_manager_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE status = 'ready'),
    COUNT(*) FILTER (WHERE status = 'parsing'),
    COUNT(*) FILTER (WHERE status = 'failed'),
    COUNT(*)
    INTO v_ready_count, v_parsing_count, v_failed_count, v_total_count
    FROM public.manager_knowledge_documents
   WHERE manager_id = p_manager_id;

  RETURN json_build_object(
    'manager_id', v_manager.id,
    'enabled', COALESCE(v_manager.public_qa_enabled, false),
    'welcome_message', v_manager.public_qa_welcome_message,
    'lead_capture_mode', COALESCE(v_manager.public_qa_lead_capture_mode, 'card_after_3_turns'),
    'display_name', COALESCE(v_manager.partner_card_display_name, ''),
    'avatar_url', v_manager.avatar_url,
    'tagline', v_manager.tagline,
    'is_example', COALESCE(v_manager.public_card_is_example, false),
    'knowledge_index_status', COALESCE(v_manager.knowledge_index_status, 'none'),
    'ready_doc_count', COALESCE(v_ready_count, 0),
    'parsing_doc_count', COALESCE(v_parsing_count, 0),
    'failed_doc_count', COALESCE(v_failed_count, 0),
    'total_doc_count', COALESCE(v_total_count, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_qa_config(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_qa_config(UUID) TO anon, authenticated;