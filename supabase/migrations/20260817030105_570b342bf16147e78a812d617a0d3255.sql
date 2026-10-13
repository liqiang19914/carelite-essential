CREATE OR REPLACE FUNCTION public.delete_help_faq(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_is_admin boolean;
  v_root     uuid;
  v_deleted  integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT public.is_admin(v_uid) INTO v_is_admin;

  IF v_is_admin THEN
    DELETE FROM public.help_faqs WHERE id = p_id AND scope = 'platform';
  ELSE
    SELECT (p.parent_manager_id IS NULL OR p.sub_role = 'admin') INTO v_is_admin
    FROM public.profiles p
    WHERE p.id = v_uid AND p.role = 'manager';

    IF v_is_admin IS NOT TRUE THEN
      RAISE EXCEPTION '仅企业管理员可修改帮助内容' USING ERRCODE = '42501';
    END IF;

    SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
      INTO v_root
      FROM public.profiles p
      WHERE p.id = v_uid;

    DELETE FROM public.help_faqs
    WHERE id = p_id AND scope = 'merchant' AND root_manager_id = v_root;
  END IF;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_help_faq(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_help_faq(uuid) TO authenticated;