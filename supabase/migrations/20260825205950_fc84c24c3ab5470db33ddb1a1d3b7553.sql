-- 修复并发删除：两个管理员同时删同一条评论时，第二个请求不再重复递减评论数。
-- 改为 DELETE ... RETURNING 并用 FOUND 校验，真正删到行才更新帖子计数。
CREATE OR REPLACE FUNCTION public.delete_reputation_comment(
  p_comment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_post_id uuid;
  v_post_root uuid;
  v_root uuid;
  v_comment_count integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT c.post_id, p.root_manager_id
    INTO v_post_id, v_post_root
  FROM public.reputation_comments c
  JOIN public.reputation_posts p ON p.id = c.post_id
  WHERE c.id = p_comment_id;

  IF v_post_id IS NULL THEN
    RAISE EXCEPTION '评论不存在或已被删除' USING ERRCODE = '42501';
  END IF;

  IF public.is_admin(v_caller) THEN
    v_root := v_post_root;
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_caller);
    IF v_root IS DISTINCT FROM v_post_root THEN
      RAISE EXCEPTION '无权删除该评论' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_enterprise_permission('reputation', v_caller) THEN
      RAISE EXCEPTION '当前角色没有「达人口碑」权限，请联系企业管理员开通' USING ERRCODE = '42501';
    END IF;
  END IF;

  DELETE FROM public.reputation_comments
  WHERE id = p_comment_id
  RETURNING post_id INTO v_post_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '评论不存在或已被删除' USING ERRCODE = '42501';
  END IF;

  UPDATE public.reputation_posts
     SET comment_count = GREATEST(COALESCE(comment_count, 0) - 1, 0),
         updated_at = now()
   WHERE id = v_post_id
  RETURNING comment_count INTO v_comment_count;

  RETURN jsonb_build_object(
    'id', p_comment_id,
    'post_id', v_post_id,
    'comment_count', COALESCE(v_comment_count, 0)
  );
END;
$function$;

-- 口碑帖子表对客户端不授权（全走 RPC），Realtime 的行变更监听因没有可读策略
-- 收不到事件，客户端详情页与瀑布流拿不到评论数变化。
-- 改由数据库主动广播最小字段（仅帖子 id 与计数），并且只在评论数/点赞数变化时
-- 推送：公开详情每次读取都会自增阅读量，若所有更新都推送，客户端刷新会形成死循环。
CREATE OR REPLACE FUNCTION public.notify_reputation_post_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_post_id uuid;
  v_root uuid;
  v_payload jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_post_id := OLD.id;
    v_root := OLD.root_manager_id;
  ELSE
    v_post_id := NEW.id;
    v_root := NEW.root_manager_id;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF COALESCE(NEW.comment_count, 0) IS NOT DISTINCT FROM COALESCE(OLD.comment_count, 0)
       AND COALESCE(NEW.like_count, 0) IS NOT DISTINCT FROM COALESCE(OLD.like_count, 0) THEN
      RETURN NULL;
    END IF;
  END IF;

  v_payload := jsonb_build_object(
    'post_id', v_post_id,
    'comment_count', COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.comment_count ELSE NEW.comment_count END, 0),
    'like_count', COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.like_count ELSE NEW.like_count END, 0)
  );

  PERFORM realtime.send(v_payload, 'post_update', 'reputation-post:' || v_post_id::text, false);
  PERFORM realtime.send(v_payload, 'post_update', 'reputation-enterprise:' || v_root::text, false);

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reputation_post_changed ON public.reputation_posts;
CREATE TRIGGER trg_reputation_post_changed
AFTER UPDATE OR DELETE ON public.reputation_posts
FOR EACH ROW EXECUTE FUNCTION public.notify_reputation_post_changed();

REVOKE ALL ON FUNCTION public.notify_reputation_post_changed() FROM PUBLIC, anon, authenticated;