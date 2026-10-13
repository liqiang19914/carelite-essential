DROP FUNCTION IF EXISTS public.admin_list_manager_knowledge_overview();

CREATE FUNCTION public.admin_list_manager_knowledge_overview()
RETURNS TABLE(
  manager_id UUID,
  display_name TEXT,
  is_example BOOLEAN,
  is_recommended BOOLEAN,
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
AS $function$
DECLARE v_uid UUID := auth.uid();
BEGIN
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅超级管理员可访问';
  END IF;
  RETURN QUERY
  SELECT m.id,
         COALESCE(NULLIF(m.partner_card_display_name, ''), p.nickname, '未命名')::TEXT,
         COALESCE(m.is_example, false),
         COALESCE(m.is_recommended, false),
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
$function$;

REVOKE EXECUTE ON FUNCTION public.admin_list_manager_knowledge_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_manager_knowledge_overview() TO authenticated;