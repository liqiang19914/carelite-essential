CREATE OR REPLACE FUNCTION public.get_admin_pending_counts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅管理员可查看' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'pending_products',
      (SELECT count(*) FROM public.products WHERE status = 'pending_review'),
    'pending_courses',
      (SELECT count(*) FROM public.manager_courses WHERE review_status = 'pending_review'),
    'pending_content',
      (SELECT count(*) FROM public.manager_content_items
        WHERE is_published = true AND moderation_status IN ('manual_review','flagged','pending'))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_admin_pending_counts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_pending_counts() TO authenticated;