CREATE OR REPLACE FUNCTION public.list_my_help_faqs()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid    uuid := auth.uid();
  v_root   uuid;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
    INTO v_root
    FROM public.profiles p
    WHERE p.id = v_uid AND p.role = 'manager';

  IF v_root IS NULL THEN
    RAISE EXCEPTION '仅商户可管理帮助内容' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_agg(x ORDER BY x.sort_order, x.created_at, x.id)
  INTO v_result
  FROM (
    SELECT f.id, f.question, f.answer, f.sort_order
    FROM public.help_faqs f
    WHERE f.scope = 'merchant' AND f.root_manager_id = v_root AND f.audience = 'user'
  ) x;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_help_faqs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_help_faqs() TO authenticated;