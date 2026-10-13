-- AI 分享快照有效期 7 天 → 30 天
-- 仅改 create_share_snapshot 的 p_expires_hours 默认值（168 → 720），签名不变，无旧重载残留风险
CREATE OR REPLACE FUNCTION public.create_share_snapshot(
  p_message_source text,
  p_message_id text,
  p_snapshot_content text,
  p_snapshot_summary text DEFAULT NULL::text,
  p_conversation_id text DEFAULT NULL::text,
  p_session_id text DEFAULT NULL::text,
  p_user_id uuid DEFAULT NULL::uuid,
  p_expires_hours integer DEFAULT 720
)
RETURNS TABLE(public_token uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_token uuid := gen_random_uuid();
  v_summary text := COALESCE(NULLIF(p_snapshot_summary, ''), LEFT(p_snapshot_content, 120));
BEGIN
  -- 快照表无消息维度唯一约束（不同用户/不同次分享各自一行，按 expires_at 过期清理）
  INSERT INTO ai_share_snapshots (
    public_token, message_source, message_id, snapshot_content,
    snapshot_summary, conversation_id, session_id, owner_user_id, expires_at, is_revoked
  ) VALUES (
    v_token, p_message_source, p_message_id, p_snapshot_content,
    v_summary, NULLIF(p_conversation_id, ''), NULLIF(p_session_id, ''),
    p_user_id, NOW() + make_interval(hours => COALESCE(p_expires_hours, 720)), false
  );

  RETURN QUERY SELECT v_token;
END;
$function$;
