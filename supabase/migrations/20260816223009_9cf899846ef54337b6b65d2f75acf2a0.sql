-- 审核/删除先校验登录态，避免未登录访客探测帖子存在性。
CREATE OR REPLACE FUNCTION public.moderate_reputation_post(
  p_post_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id INTO v_root
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权操作该帖子' USING ERRCODE = '42501';
  END IF;

  IF p_action = 'approve' THEN
    v_status := 'passed';
  ELSIF p_action = 'block' THEN
    v_status := 'blocked';
  ELSE
    RAISE EXCEPTION '不支持的审核动作' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.reputation_posts
     SET moderation_status = v_status,
         review_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
         updated_at = now()
   WHERE id = p_post_id;

  RETURN jsonb_build_object('id', p_post_id, 'moderation_status', v_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_reputation_post(p_post_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_author uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id, author_user_id INTO v_root, v_author
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_root IS NULL THEN
    RETURN false;
  END IF;

  IF auth.uid() IS DISTINCT FROM v_author
     AND NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权删除该帖子' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.reputation_posts WHERE id = p_post_id;
  RETURN true;
END;
$function$;