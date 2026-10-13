-- ============================================================
-- 修复：分享快照 / 消息反馈的 ID 参数类型
-- 背景：create_share_snapshot / record_feedback / get_my_feedback 的
--   p_message_id / p_conversation_id / p_session_id 声明为 uuid，
--   但跨消息来源的 ID 并不都是 UUID：
--   - 健管师公开问答(public_qa)前端临时消息 id 为 'a-1726...' 字符串
--   - openclaw 会话 id(lobsterConversationId) 也非 UUID
--   传入后 Postgres 报 22023 invalid input syntax for type uuid，
--   表现为「创建分享失败」、点赞静默失败（错误被前端 toast 吞掉）。
-- 说明：库内实际 schema 为演进后的增强版（ai_share_snapshots 含
--   owner_user_id/manager/品牌字段；ai_message_feedback 含 manager_id），
--   本迁移只做「uuid -> text 无损转换 + 函数签名重写」，全部幂等。
-- ============================================================

-- 1. ID 列 uuid -> text（uuid 标准文本无损保留；索引自动重建）
ALTER TABLE public.ai_share_snapshots
  ALTER COLUMN message_id TYPE text,
  ALTER COLUMN conversation_id TYPE text,
  ALTER COLUMN session_id TYPE text;

ALTER TABLE public.ai_message_feedback
  ALTER COLUMN message_id TYPE text,
  ALTER COLUMN conversation_id TYPE text,
  ALTER COLUMN session_id TYPE text;

-- 非健管师来源（小凯/openclaw）的反馈无 manager，允许 NULL
ALTER TABLE public.ai_message_feedback ALTER COLUMN manager_id DROP NOT NULL;

-- 2. 清理历史重载（旧 uuid 签名 / 6 参数 feedback），避免 PostgREST 歧义
DROP FUNCTION IF EXISTS public.create_share_snapshot(uuid, text, text, text, uuid, uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.create_share_snapshot(text, uuid, text, text, uuid, uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.create_share_snapshot(text, text, text, text, text, text, uuid, integer);
DROP FUNCTION IF EXISTS public.record_feedback(text, uuid, text, uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.record_feedback(text, uuid, text, uuid, uuid);
DROP FUNCTION IF EXISTS public.record_feedback(text, text, text, text, text, uuid);
DROP FUNCTION IF EXISTS public.get_my_feedback(text, uuid);

-- 3. 新签名：跨来源 ID 一律 text；p_user_id 仍是平台 auth 用户 uuid
CREATE OR REPLACE FUNCTION public.create_share_snapshot(
  p_message_source text,
  p_message_id text,
  p_snapshot_content text,
  p_snapshot_summary text DEFAULT NULL::text,
  p_conversation_id text DEFAULT NULL::text,
  p_session_id text DEFAULT NULL::text,
  p_user_id uuid DEFAULT NULL::uuid,
  p_expires_hours integer DEFAULT 168
)
RETURNS TABLE(public_token uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_token uuid := gen_random_uuid();
  v_summary text := COALESCE(NULLIF(p_snapshot_summary, ''), LEFT(p_snapshot_content, 120));
BEGIN
  -- 无消息维度唯一约束：不同用户/不同次分享各自一行，按 expires_at 过期清理
  INSERT INTO ai_share_snapshots (
    public_token, message_source, message_id, snapshot_content,
    snapshot_summary, conversation_id, session_id, owner_user_id, expires_at, is_revoked
  ) VALUES (
    v_token, p_message_id, p_message_id, p_snapshot_content,
    v_summary, NULLIF(p_conversation_id, ''), NULLIF(p_session_id, ''),
    p_user_id, NOW() + make_interval(hours => COALESCE(p_expires_hours, 168)), false
  );

  RETURN QUERY SELECT v_token;
END;
$$;

-- record_feedback：p_feedback_type 传 NULL = 取消；like/dislike 互斥（先删后插）
CREATE OR REPLACE FUNCTION public.record_feedback(
  p_message_source text,
  p_message_id text,
  p_feedback_type text,
  p_conversation_id text DEFAULT NULL::text,
  p_session_id text DEFAULT NULL::text,
  p_user_id uuid DEFAULT NULL::uuid,
  p_manager_id uuid DEFAULT NULL::uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_user_id, auth.uid());
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '必须登录后才能反馈';
  END IF;

  IF p_feedback_type IS NULL THEN
    DELETE FROM ai_message_feedback
     WHERE user_id = v_user_id
       AND message_source = p_message_source
       AND message_id = p_message_id;
    RETURN;
  END IF;

  IF p_feedback_type NOT IN ('like', 'dislike') THEN
    RAISE EXCEPTION 'feedback_type 只能是 like/dislike 或 NULL(取消)';
  END IF;

  DELETE FROM ai_message_feedback
   WHERE user_id = v_user_id
     AND message_source = p_message_source
     AND message_id = p_message_id;

  INSERT INTO ai_message_feedback (
    user_id, manager_id, message_source, message_id, feedback_type,
    conversation_id, session_id
  ) VALUES (
    v_user_id, p_manager_id, p_message_source, p_message_id, p_feedback_type,
    NULLIF(p_conversation_id, ''), NULLIF(p_session_id, '')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_feedback(
  p_message_source text,
  p_message_id text
)
RETURNS TABLE(feedback_type text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO public
AS $$
  SELECT f.feedback_type
  FROM ai_message_feedback f
  WHERE f.user_id = auth.uid()
    AND f.message_source = p_message_source
    AND f.message_id = p_message_id
  ORDER BY f.created_at DESC
  LIMIT 1;
$$;

-- 4. 权限
GRANT EXECUTE ON FUNCTION public.create_share_snapshot(text, text, text, text, text, text, uuid, integer) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.record_feedback(text, text, text, text, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_feedback(text, text) TO authenticated;
