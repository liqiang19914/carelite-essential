-- ── 待认领门店：手机号与当前账号一致、尚未绑定的门店 ──────────────
CREATE OR REPLACE FUNCTION public.list_claimable_stores()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_phone TEXT;
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT phone INTO v_phone FROM public.profiles WHERE id = v_uid;
  IF v_phone IS NULL OR btrim(v_phone) = '' THEN
    RETURN json_build_object('items', '[]'::JSON);
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.name, s.phone, s.created_at, s.root_manager_id,
           m.business_name AS merchant_name
    FROM public.stores s
    LEFT JOIN public.managers m ON m.id = s.root_manager_id
    WHERE s.operator_user_id IS NULL
      AND s.status = 'active'
      AND regexp_replace(s.phone, '[^0-9]', '', 'g') = regexp_replace(v_phone, '[^0-9]', '', 'g')
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_claimable_stores() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_claimable_stores() TO authenticated;