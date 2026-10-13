-- 匿名可调的「商户是否开通健康饮食导图」公开判定：不返回任何个人评估数据。
-- 供装修模块在未登录访客场景判断是否显示导图入口卡。
CREATE OR REPLACE FUNCTION public.get_public_diet_map_status(p_mp_manager uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  IF p_mp_manager IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_mp_manager);
  END IF;

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.manager_miniprograms mm
     WHERE mm.manager_id = v_root AND mm.is_enabled = true
  ) THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.diet_map_templates t
      JOIN public.diet_map_grants g ON g.template_id = t.id
     WHERE g.root_manager_id = v_root
       AND g.is_enabled = true
       AND t.status = 'published'
  ) THEN
    RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
  END IF;

  RETURN jsonb_build_object('open', true, 'root_manager_id', v_root);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_diet_map_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_diet_map_status(uuid) TO anon, authenticated;