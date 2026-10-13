-- 升级 list_manager_conversations：加智能体筛选 / 日期范围 / 关键词 / 分页
-- 新增 count_manager_conversations 返回 total 供前端分页器用

DROP FUNCTION IF EXISTS public.list_manager_conversations(int);
DROP FUNCTION IF EXISTS public.list_manager_conversations(varchar(50), timestamptz, timestamptz, text, int, int);

CREATE OR REPLACE FUNCTION public.list_manager_conversations(
  p_agent_slug varchar(50) DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to   timestamptz DEFAULT NULL,
  p_keyword   text        DEFAULT NULL,
  p_offset    int         DEFAULT 0,
  p_limit     int         DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  agent_id uuid,
  agent_slug varchar(50),
  title varchar(200),
  status varchar(20),
  message_count int,
  created_at timestamptz,
  updated_at timestamptz,
  owner_manager_id uuid,
  client_name text,
  agent_name text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.id, c.user_id, c.agent_id,
         a.slug::varchar(50),
         c.title, c.status,
         COALESCE(c.message_count, 0)::int,
         c.created_at, c.updated_at,
         c.owner_manager_id,
         COALESCE(p.nickname, '未命名')::text AS client_name,
         COALESCE(a.name, '健管师专属')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid())
      OR (
        c.owner_manager_id IS NULL
        AND p.enterprise_id IS NOT NULL
        AND p.enterprise_id = (SELECT pr.enterprise_id FROM public.profiles pr WHERE pr.id = auth.uid())
      )
    )
    -- 智能体筛选
    AND (p_agent_slug IS NULL
         OR (p_agent_slug = 'manager-chat' AND c.agent_id IS NULL)
         OR a.slug = p_agent_slug)
    -- 日期范围（updated_at）
    AND (p_date_from IS NULL OR c.updated_at >= p_date_from)
    AND (p_date_to   IS NULL OR c.updated_at <= p_date_to)
    -- 关键词：title / client_name / agent_name ILIKE，或 messages 里的 content
    AND (p_keyword IS NULL OR char_length(trim(p_keyword)) = 0
         OR c.title ILIKE '%' || p_keyword || '%'
         OR p.nickname ILIKE '%' || p_keyword || '%'
         OR a.name ILIKE '%' || p_keyword || '%'
         OR EXISTS (
             SELECT 1 FROM public.messages m
             WHERE m.conversation_id = c.id
               AND m.content ILIKE '%' || p_keyword || '%'
         ))
  ORDER BY c.updated_at DESC
  OFFSET p_offset
  LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(varchar(50), timestamptz, timestamptz, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(varchar(50), timestamptz, timestamptz, text, int, int) TO authenticated;

-- count：同样筛选条件返回总数
CREATE OR REPLACE FUNCTION public.count_manager_conversations(
  p_agent_slug varchar(50) DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to   timestamptz DEFAULT NULL,
  p_keyword   text        DEFAULT NULL
)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT COUNT(*)
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid())
      OR (
        c.owner_manager_id IS NULL
        AND p.enterprise_id IS NOT NULL
        AND p.enterprise_id = (SELECT pr.enterprise_id FROM public.profiles pr WHERE pr.id = auth.uid())
      )
    )
    AND (p_agent_slug IS NULL
         OR (p_agent_slug = 'manager-chat' AND c.agent_id IS NULL)
         OR a.slug = p_agent_slug)
    AND (p_date_from IS NULL OR c.updated_at >= p_date_from)
    AND (p_date_to   IS NULL OR c.updated_at <= p_date_to)
    AND (p_keyword IS NULL OR char_length(trim(p_keyword)) = 0
         OR c.title ILIKE '%' || p_keyword || '%'
         OR p.nickname ILIKE '%' || p_keyword || '%'
         OR a.name ILIKE '%' || p_keyword || '%'
         OR EXISTS (
             SELECT 1 FROM public.messages m
             WHERE m.conversation_id = c.id
               AND m.content ILIKE '%' || p_keyword || '%'
         ));
$$;

REVOKE ALL ON FUNCTION public.count_manager_conversations(varchar(50), timestamptz, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_manager_conversations(varchar(50), timestamptz, timestamptz, text) TO authenticated;
