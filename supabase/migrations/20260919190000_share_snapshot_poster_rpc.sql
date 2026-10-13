-- 分享海报回写 RPC（BUG-2 修复）
--
-- 背景：ai_share_snapshots 的 owner_update RLS 策略要求 owner_user_id = uid()，
-- 但 create_share_snapshot 允许 p_user_id 为 NULL（owner_user_id 可为 NULL，
-- 如健管师公开问答场景），这类快照在 RLS 下任何人都无法 UPDATE，
-- 海报上传 CDN 后 poster_url 回写静默失败 → 原生分享页永远降级文本卡片。
--
-- 方案：SECURITY DEFINER RPC，按 token 单条回写 poster_url，
-- 仅限未过期且未撤销的快照；不放宽行级 UPDATE 策略（防止篡改快照内容）。

DROP FUNCTION IF EXISTS public.update_snapshot_poster(p_public_token text, p_poster_url text);

CREATE OR REPLACE FUNCTION public.update_snapshot_poster(
  p_public_token text,
  p_poster_url text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_public_token IS NULL OR NULLIF(trim(p_poster_url), '') IS NULL THEN
    RETURN; -- 参数不完整：静默跳过（调用方有文本卡片兜底）
  END IF;

  UPDATE ai_share_snapshots
     SET poster_url = trim(p_poster_url)
   WHERE public_token = p_public_token::uuid
     AND NOT is_revoked
     AND expires_at > now();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.update_snapshot_poster(text, text) TO anon, authenticated;
