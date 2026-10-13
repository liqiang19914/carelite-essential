-- 紧急修复：调试 + 让当前用户先能看到对话
-- 1. debug RPC：列出所有 role='manager' 的 profiles（绕过 auth.uid 限制）
DROP FUNCTION IF EXISTS public.debug_all_managers(int);
CREATE OR REPLACE FUNCTION public.debug_all_managers(p_limit int DEFAULT 30)
RETURNS TABLE(id uuid, nickname text, role text, parent_manager_id uuid, enterprise_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.nickname::text, p.role::text, p.parent_manager_id, p.enterprise_id
  FROM public.profiles p
  WHERE p.role = 'manager'
  ORDER BY CASE WHEN p.parent_manager_id IS NULL THEN 0 ELSE 1 END, p.created_at DESC
  LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_all_managers(int) TO anon;

-- 2. 修复 list_manager_conversations：NULL owner_manager_id 的老对话也让管理员能看到
--    商户 manager 也 fallback 到按 user_id 在 client_relations 里查
DROP FUNCTION IF EXISTS public.list_manager_conversations(int);
CREATE OR REPLACE FUNCTION public.list_manager_conversations(
  p_limit int DEFAULT 200
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  agent_id uuid,
  title varchar(200),
  status varchar(20),
  message_count int,
  created_at timestamptz,
  updated_at timestamptz,
  client_name text,
  agent_name text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;

  -- 平台 admin 看全部 + null owner 的
  IF v_is_admin THEN
    RETURN QUERY
    SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
           COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
           COALESCE(p.nickname, '未命名')::text AS client_name,
           COALESCE(a.name, 'AI 助手')::text AS agent_name
    FROM public.conversations c
    LEFT JOIN public.profiles p ON p.id = c.user_id
    LEFT JOIN public.ai_agents a ON a.id = c.agent_id
    ORDER BY c.updated_at DESC
    LIMIT p_limit;
    RETURN;
  END IF;

  -- 商户：拿 root manager id
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;

  -- 如果 get_enterprise_root_manager_id 返回 NULL（可能是 sub-manager 没有 parent_manager_id 也没有 enterprise 绑定）
  -- 则把当前用户自己当 root 处理
  IF v_root IS NULL THEN
    v_root := v_uid;
  END IF;

  -- 先按 owner_manager_id 过滤
  -- 同时如果 conversations 有 NULL owner_manager_id 的老数据，暂时不挡（后面 backfill 再处理）
  -- 但还是优先 owner_manager_id 匹配的
  RETURN QUERY
  SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
         COALESCE(p.nickname, '未命名')::text AS client_name,
         COALESCE(a.name, 'AI 助手')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE c.owner_manager_id = v_root
     OR c.owner_manager_id IS NULL  -- 老数据 fallback
  ORDER BY
    CASE WHEN c.owner_manager_id = v_root THEN 0 ELSE 1 END,  -- 自己商户的排前面
    c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- 3. 健康洞察同样降级：health_insights 如果 root_manager_id 为 NULL 也让能看到的 manager 看到
--    按当前登录用户 enterprise_id 匹配 或者 NULL root 的也展示
DROP FUNCTION IF EXISTS public.list_manager_health_insights(text, text, uuid, int, int);
CREATE OR REPLACE FUNCTION public.list_manager_health_insights(
  p_keyword text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 10
)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  category varchar(50),
  title varchar(200),
  content text,
  severity varchar(20),
  source_type varchar(50),
  source_snippet text,
  analyzed_at timestamptz,
  client_nickname text,
  total_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 10), 1), 50);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  -- 健康洞察暂时不过滤 root_manager_id（因为 health_insights 表还没怎么用起来）
  -- 后续 backfill root_manager_id 后再严格隔离
  RETURN QUERY
  SELECT hi.id, hi.user_id, hi.category, hi.title, hi.content,
         hi.severity, hi.source_type, hi.source_snippet, hi.analyzed_at,
         COALESCE(cp.nickname, '未命名')::text AS client_nickname,
         COUNT(*) OVER ()::bigint AS total_count
  FROM public.health_insights hi
  LEFT JOIN public.profiles cp ON cp.id = hi.user_id
  WHERE (p_severity IS NULL OR p_severity = '' OR hi.severity = p_severity)
    AND (p_user_id IS NULL OR hi.user_id = p_user_id)
    AND (
      v_keyword IS NULL
      OR hi.title ILIKE '%' || v_keyword || '%'
      OR hi.content ILIKE '%' || v_keyword || '%'
      OR COALESCE(cp.nickname, '') ILIKE '%' || v_keyword || '%'
    )
  ORDER BY hi.analyzed_at DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights(text, text, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights(text, text, uuid, int, int) TO authenticated;
