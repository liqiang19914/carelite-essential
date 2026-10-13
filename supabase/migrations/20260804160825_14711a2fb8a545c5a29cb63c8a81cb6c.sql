-- 归属解析确定性加固：
-- 1) 只认 role='manager' 的绑定。线上存在指向普通用户 profile 的历史脏绑定，
--    普通 H5 分支没有企业根过滤，脏绑定一旦成为「最新」就会把归属解析到不存在的中心，
--    客户端入口会无声消失。
-- 2) created_at 相同时补 id 兜底，避免同秒写入的多条绑定每次解析出不同结果。
CREATE OR REPLACE FUNCTION public.get_my_diet_map_access(
  p_mp_manager uuid DEFAULT NULL::uuid,
  p_record_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_manager uuid;
  v_trusted boolean := false;
  v_tpl public.diet_map_templates%ROWTYPE;
  v_record uuid;
  v_latest jsonb := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再查看健康饮食导图' USING ERRCODE = '28000';
  END IF;

  IF p_mp_manager IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_mp_manager);
  END IF;

  -- 优先取与该企业根下任一管理师的有效绑定关系，作为归属商户
  IF v_root IS NOT NULL THEN
    SELECT cr.manager_id INTO v_manager
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND mp.role = 'manager'
       AND COALESCE(mp.parent_manager_id, mp.id) = v_root
     ORDER BY (cr.manager_id = p_mp_manager) DESC, cr.created_at DESC, cr.id DESC
     LIMIT 1;
  ELSE
    -- 普通 H5 无 mp_manager：回落到客户自己绑定的管理师所属企业根
    SELECT cr.manager_id, COALESCE(mp.parent_manager_id, mp.id)
      INTO v_manager, v_root
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND mp.role = 'manager'
     ORDER BY cr.created_at DESC, cr.id DESC
     LIMIT 1;
  END IF;

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  -- 可信来源：已绑定该企业下的管理师，或该企业确有启用中的品牌小程序
  v_trusted := v_manager IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.manager_miniprograms mm
       WHERE mm.manager_id = v_root AND mm.is_enabled = true
    );

  IF NOT v_trusted THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  SELECT t.* INTO v_tpl
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.status = 'published'
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
  END IF;

  -- 定位档案：显式指定优先，否则用默认档案
  IF p_record_id IS NOT NULL THEN
    SELECT hr.id INTO v_record
      FROM public.health_records hr
     WHERE hr.id = p_record_id AND hr.user_id = v_uid;
  END IF;

  IF v_record IS NULL THEN
    SELECT hr.id INTO v_record
      FROM public.health_records hr
     WHERE hr.user_id = v_uid
     ORDER BY hr.is_default DESC, hr.created_at
     LIMIT 1;
  END IF;

  IF v_record IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id', a.id,
             'status', a.status,
             'type_code', a.type_code,
             'submitted_at', a.submitted_at,
             'record_id', a.record_id,
             'config_version', a.config_version
           )
      INTO v_latest
      FROM public.diet_map_assessments a
     WHERE a.record_id = v_record
       AND a.template_id = v_tpl.id
     ORDER BY a.submitted_at DESC, a.id DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'open', true,
    'root_manager_id', v_root,
    'manager_id', v_manager,
    'record_id', v_record,
    'template', jsonb_build_object(
      'id', v_tpl.id,
      'map_key', v_tpl.map_key,
      'title', v_tpl.title,
      'description', v_tpl.description,
      'config_version', v_tpl.config_version,
      'scoring_confirmed', v_tpl.scoring_confirmed,
      'questions', v_tpl.questions,
      'report', v_tpl.report
    ),
    'latest', v_latest
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_diet_map_access(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_diet_map_access(uuid, uuid) TO authenticated;