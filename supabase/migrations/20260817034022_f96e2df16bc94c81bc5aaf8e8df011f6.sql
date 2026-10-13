CREATE OR REPLACE FUNCTION public.set_manager_recommended(p_manager_id uuid, p_is_recommended boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_uid UUID := auth.uid();
BEGIN
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅超级管理员可操作';
  END IF;
  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '缺少管理师';
  END IF;
  UPDATE public.managers
     SET is_recommended = COALESCE(p_is_recommended, false),
         updated_at = now()
   WHERE id = p_manager_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.set_manager_recommended(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_manager_recommended(uuid, boolean) TO authenticated;