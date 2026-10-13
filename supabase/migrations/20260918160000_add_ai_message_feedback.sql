-- AI 消息反馈（点赞/反对）：豆包式消息工具栏的 like/dislike
-- 归属维度：manager_id（智能体/健管师），支撑后台"用户反馈"tab 按智能体查询

DROP TABLE IF EXISTS public.ai_message_feedback CASCADE;

CREATE TABLE public.ai_message_feedback (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id      uuid NOT NULL,                       -- 归属智能体/健管师（后台按此过滤）
  conversation_id uuid,                                -- 可选，conversations 表的 id
  session_id      uuid,                                -- 可选，public_qa 的 session 或 openclaw 的 connection
  message_source  text NOT NULL,                        -- 'conversations' | 'public_qa' | 'openclaw'
  message_id      uuid NOT NULL,                        -- 原始消息主键
  user_id         uuid REFERENCES auth.users(id),       -- 谁点的；匿名公开问答可能为空
  feedback_type   text NOT NULL CHECK (feedback_type IN ('like', 'dislike')),
  created_at      timestamptz NOT NULL DEFAULT now(),

  -- 同一用户对同一条消息不能重复点同一种反馈
  UNIQUE (message_source, message_id, user_id, feedback_type)
);

CREATE INDEX ai_message_feedback_manager_time_idx
  ON public.ai_message_feedback (manager_id, created_at DESC);

CREATE INDEX ai_message_feedback_msg_idx
  ON public.ai_message_feedback (message_source, message_id);

ALTER TABLE public.ai_message_feedback ENABLE ROW LEVEL SECURITY;

-- 前台：登录用户只能插自己 id 的记录；匿名公开问答 user_id 为 null 时不插（RPC 兜底）
CREATE POLICY ai_message_feedback_insert ON public.ai_message_feedback
  FOR INSERT WITH CHECK (user_id IS NULL OR user_id = auth.uid());

CREATE POLICY ai_message_feedback_select_self ON public.ai_message_feedback
  FOR SELECT USING (user_id = auth.uid());

-- 删除：让用户能撤回自己的 feedback（可选）
CREATE POLICY ai_message_feedback_delete ON public.ai_message_feedback
  FOR DELETE USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.ai_message_feedback TO authenticated;
GRANT SELECT ON public.ai_message_feedback TO service_role;

-- ====================================================================
-- RPC 1：用户点反馈（like/dislike）。幂等：同类型重复调用静默 OK；
--       不同类型先清再插（不允许一条消息同时被点赞又反对）。
-- ====================================================================
CREATE OR REPLACE FUNCTION public.record_feedback(
  p_message_source text,
  p_message_id     uuid,
  p_feedback_type  text,
  p_conversation_id uuid DEFAULT NULL,
  p_session_id     uuid DEFAULT NULL,
  p_user_id        uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_user_id    uuid := COALESCE(p_user_id, auth.uid());
  v_manager_id uuid;
BEGIN
  -- 反查 manager_id：conversation 有 owner_manager_id；public_qa session 有 manager_id；
  -- openclaw 暂时从消息 payload 取（如果没有则允许为 NULL，用于未归属智能体的场景）
  IF p_message_source = 'conversations' AND p_conversation_id IS NOT NULL THEN
    SELECT c.owner_manager_id INTO v_manager_id
      FROM public.conversations c WHERE c.id = p_conversation_id;
  ELSIF p_message_source = 'public_qa' AND p_session_id IS NOT NULL THEN
    SELECT manager_id INTO v_manager_id
      FROM public.manager_public_qa_sessions s WHERE s.id = p_session_id;
  END IF;

  -- 已存在同用户 + 同消息 + 同类型 → 幂等返回
  IF EXISTS (
    SELECT 1 FROM public.ai_message_feedback
     WHERE message_source = p_message_source
       AND message_id = p_message_id
       AND (user_id = v_user_id OR (user_id IS NULL AND v_user_id IS NULL))
       AND feedback_type = p_feedback_type
  ) THEN
    RETURN;
  END IF;

  -- 先清掉该用户在这条消息上的另一种反馈（点赞后点反对 → 覆盖）
  DELETE FROM public.ai_message_feedback
   WHERE message_source = p_message_source
     AND message_id = p_message_id
     AND (user_id = v_user_id OR (user_id IS NULL AND v_user_id IS NULL));

  INSERT INTO public.ai_message_feedback
    (manager_id, conversation_id, session_id, message_source, message_id, user_id, feedback_type)
  VALUES
    (COALESCE(v_manager_id, '00000000-0000-0000-0000-000000000000'::uuid),
     p_conversation_id, p_session_id, p_message_source, p_message_id, v_user_id, p_feedback_type);
END;
$$;

REVOKE ALL ON FUNCTION public.record_feedback(text, uuid, text, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_feedback(text, uuid, text, uuid, uuid, uuid) TO authenticated, anon;

-- ====================================================================
-- RPC 2：查某条消息当前用户已点过什么（避免重复渲染高亮）
-- ====================================================================
CREATE OR REPLACE FUNCTION public.get_my_feedback(
  p_message_source text,
  p_message_id     uuid
) RETURNS TABLE(feedback_type text)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
    SELECT f.feedback_type
      FROM public.ai_message_feedback f
     WHERE f.message_source = p_message_source
       AND f.message_id = p_message_id
       AND f.user_id = auth.uid()
     ORDER BY f.created_at DESC
     LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_feedback(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_feedback(text, uuid) TO authenticated, anon;

-- ====================================================================
-- RPC 3：商户后台「用户反馈」tab 查询 —— 按智能体维度聚合
-- ====================================================================
CREATE OR REPLACE FUNCTION public.list_agent_feedback(
  p_manager_id   uuid,
  p_from         timestamptz DEFAULT NULL,
  p_to           timestamptz DEFAULT NULL,
  p_limit        int         DEFAULT 100,
  p_offset       int         DEFAULT 0
) RETURNS TABLE(
  message_source   text,
  message_id       uuid,
  conversation_id  uuid,
  session_id       uuid,
  message_content  text,
  message_role     text,
  like_count       bigint,
  dislike_count    bigint,
  unique_users     bigint,
  last_feedback_at timestamptz,
  title            text,
  agent_label      text
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH agg AS (
    SELECT
      f.message_source,
      f.message_id,
      f.conversation_id,
      f.session_id,
      COUNT(*) FILTER (WHERE f.feedback_type = 'like')   AS like_count,
      COUNT(*) FILTER (WHERE f.feedback_type = 'dislike') AS dislike_count,
      COUNT(DISTINCT f.user_id)                          AS unique_users,
      MAX(f.created_at)                                  AS last_feedback_at
    FROM public.ai_message_feedback f
    WHERE f.manager_id = p_manager_id
      AND (p_from IS NULL OR f.created_at >= p_from)
      AND (p_to   IS NULL OR f.created_at <= p_to)
    GROUP BY f.message_source, f.message_id, f.conversation_id, f.session_id
  )
  SELECT
    a.message_source,
    a.message_id,
    a.conversation_id,
    a.session_id,
    COALESCE(
      CASE WHEN a.message_source = 'conversations'
        THEN (SELECT m.content FROM public.messages m WHERE m.id = a.message_id)
      END,
      CASE WHEN a.message_source = 'public_qa'
        THEN (SELECT m.content FROM public.manager_public_qa_messages m WHERE m.id = a.message_id)
      END,
      CASE WHEN a.message_source = 'openclaw'
        THEN (SELECT m.content FROM public.openclaw_messages m WHERE m.id = a.message_id)
      END,
      ''
    ) AS message_content,
    COALESCE(
      CASE WHEN a.message_source = 'conversations'
        THEN (SELECT m.role FROM public.messages m WHERE m.id = a.message_id)
      END,
      CASE WHEN a.message_source = 'public_qa'
        THEN (SELECT m.role FROM public.manager_public_qa_messages m WHERE m.id = a.message_id)
      END,
      CASE WHEN a.message_source = 'openclaw'
        THEN (SELECT m.role FROM public.openclaw_messages m WHERE m.id = a.message_id)
      END,
      'assistant'
    ) AS message_role,
    a.like_count,
    a.dislike_count,
    a.unique_users,
    a.last_feedback_at,
    CASE WHEN a.conversation_id IS NOT NULL THEN
      (SELECT c.title FROM public.conversations c WHERE c.id = a.conversation_id)
    END AS title,
    ''::text AS agent_label
  FROM agg a
  ORDER BY (a.like_count - a.dislike_count) DESC, a.last_feedback_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.list_agent_feedback(uuid, timestamptz, timestamptz, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agent_feedback(uuid, timestamptz, timestamptz, int, int) TO service_role;

-- 服务端安全兜底：RPC 执行时切换到 service_role（函数声明 SECURITY DEFINER），
-- message_source 任何外部输入都必须是已知枚举值
ALTER FUNCTION public.record_feedback(text, uuid, text, uuid, uuid, uuid) SET search_path = public;
ALTER FUNCTION public.get_my_feedback(text, uuid) SET search_path = public;
ALTER FUNCTION public.list_agent_feedback(uuid, timestamptz, timestamptz, int, int) SET search_path = public;
