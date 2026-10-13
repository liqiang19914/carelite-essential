-- ============================================================
-- 管理师 RAG V2：升级到阿里云百炼
-- ============================================================

-- 1. managers 表加百炼智能体相关字段
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS knowledge_index_id TEXT,
  ADD COLUMN IF NOT EXISTS knowledge_index_status TEXT DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS knowledge_model TEXT DEFAULT 'qwen3.6-plus',
  ADD COLUMN IF NOT EXISTS knowledge_system_prompt TEXT;

-- 兜底 CHECK 约束（不存在再加）
DO $$ BEGIN
  ALTER TABLE public.managers
    ADD CONSTRAINT managers_knowledge_index_status_check
    CHECK (knowledge_index_status IN ('none','building','ready','failed'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2. manager_knowledge_documents 加 source 字段，区分用户上传与系统聚合
ALTER TABLE public.manager_knowledge_documents
  ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'user_upload';

DO $$ BEGIN
  ALTER TABLE public.manager_knowledge_documents
    ADD CONSTRAINT mkd_source_check
    CHECK (source IN ('user_upload', 'auto_sync'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 回填已有行
UPDATE public.manager_knowledge_documents SET source = 'user_upload' WHERE source IS NULL;

CREATE INDEX IF NOT EXISTS idx_mkd_source ON public.manager_knowledge_documents(manager_id, source);

-- 3. RPC: 管理师更新自己的智能体配置（model + system_prompt）
CREATE OR REPLACE FUNCTION public.update_manager_knowledge_settings(
  p_model TEXT,
  p_system_prompt TEXT
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_is_manager BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  -- 必须是管理师本人
  SELECT EXISTS (SELECT 1 FROM public.managers WHERE id = v_uid) INTO v_is_manager;
  IF NOT v_is_manager THEN
    RETURN json_build_object('error', '仅健康管理师可操作');
  END IF;

  -- 截断 system_prompt 到 2000 字（防超）
  IF p_system_prompt IS NOT NULL AND length(p_system_prompt) > 2000 THEN
    p_system_prompt := substring(p_system_prompt, 1, 2000);
  END IF;

  UPDATE public.managers
     SET knowledge_model = COALESCE(NULLIF(trim(p_model), ''), 'qwen3.6-plus'),
         knowledge_system_prompt = NULLIF(trim(COALESCE(p_system_prompt,'')), ''),
         updated_at = NOW()
   WHERE id = v_uid;

  RETURN json_build_object('success', true);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_manager_knowledge_settings(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_manager_knowledge_settings(TEXT, TEXT) TO authenticated;

-- 4. RPC: 管理师 / admin 读取智能体配置 + Index 状态（前端展示用）
CREATE OR REPLACE FUNCTION public.get_manager_knowledge_settings(p_manager_id UUID DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_is_admin BOOLEAN;
  v_target UUID;
  v_row RECORD;
  v_doc_count INT;
  v_auto_count INT;
  v_last_train TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  SELECT public.is_admin(v_uid) INTO v_is_admin;
  IF p_manager_id IS NOT NULL AND v_is_admin THEN
    v_target := p_manager_id;
  ELSE
    v_target := v_uid;
  END IF;

  SELECT m.id, m.knowledge_index_id, m.knowledge_index_status,
         m.knowledge_model, m.knowledge_system_prompt
    INTO v_row
    FROM public.managers m
   WHERE m.id = v_target;

  IF NOT FOUND THEN
    RETURN json_build_object('error', '管理师不存在');
  END IF;

  SELECT COUNT(*) FILTER (WHERE source = 'user_upload'),
         COUNT(*) FILTER (WHERE source = 'auto_sync'),
         MAX(updated_at) FILTER (WHERE source = 'auto_sync')
    INTO v_doc_count, v_auto_count, v_last_train
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
    'last_train_at', v_last_train
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_manager_knowledge_settings(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_knowledge_settings(UUID) TO authenticated;

-- 5. RPC: admin 列出所有管理师的训练总览（按训练时间 / 状态排序）
CREATE OR REPLACE FUNCTION public.admin_list_manager_knowledge_overview()
RETURNS TABLE(
  manager_id UUID,
  display_name TEXT,
  is_example BOOLEAN,
  knowledge_index_id TEXT,
  knowledge_index_status TEXT,
  knowledge_model TEXT,
  user_upload_count INT,
  auto_sync_count INT,
  last_train_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_uid UUID := auth.uid();
BEGIN
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅超级管理员可访问';
  END IF;
  RETURN QUERY
  SELECT m.id,
         COALESCE(NULLIF(m.partner_card_display_name, ''), p.nickname, '未命名')::TEXT,
         COALESCE(m.is_example, false),
         m.knowledge_index_id,
         COALESCE(m.knowledge_index_status, 'none'),
         COALESCE(m.knowledge_model, 'qwen3.6-plus'),
         COALESCE((SELECT COUNT(*)::INT FROM public.manager_knowledge_documents d
                     WHERE d.manager_id = m.id AND d.source = 'user_upload'), 0),
         COALESCE((SELECT COUNT(*)::INT FROM public.manager_knowledge_documents d
                     WHERE d.manager_id = m.id AND d.source = 'auto_sync'), 0),
         (SELECT MAX(d.updated_at) FROM public.manager_knowledge_documents d
            WHERE d.manager_id = m.id AND d.source = 'auto_sync')
    FROM public.managers m
    LEFT JOIN public.profiles p ON p.id = m.id
   ORDER BY COALESCE(m.is_example, false), m.created_at DESC NULLS LAST;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_list_manager_knowledge_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_manager_knowledge_overview() TO authenticated;