-- ⑩ 覆盖概览：商户视角不再按 template_id 过滤（切到自有版本后历史仍在参考版的 id 下），
--    改为按本企业的归属统计，避免刚切版本就显示「0 人评估过」。
CREATE OR REPLACE FUNCTION public.get_diet_map_coverage(p_template_id uuid DEFAULT NULL::uuid, p_root_manager_id uuid DEFAULT NULL::uuid, p_cursor uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_scope uuid[];
  v_limit int;
  v_template uuid;
  v_merchant_open int := NULL;
  v_client_total int := NULL;
  v_assessed_clients int := 0;
  v_assessed_records int := 0;
  v_scored int := 0;
  v_pending int := 0;
  v_dist jsonb := '{"S":0,"D":0,"G":0,"N":0,"C":0,"A":0}'::jsonb;
  v_clients jsonb := '[]'::jsonb;
  v_next uuid := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  v_is_admin := public.is_admin(v_uid);
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 50);

  IF v_is_admin THEN
    v_root := p_root_manager_id;
    v_template := p_template_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_uid);
    IF v_root IS NULL THEN
      RAISE EXCEPTION '仅平台管理员或健康管理师可查看覆盖情况' USING ERRCODE = '42501';
    END IF;
    IF p_root_manager_id IS NOT NULL AND p_root_manager_id <> v_root THEN
      RAISE EXCEPTION '只能查看本企业的覆盖情况' USING ERRCODE = '42501';
    END IF;
    -- 商户侧只按企业归属统计，不锁定某一个版本
    v_template := NULL;
  END IF;

  IF v_root IS NOT NULL THEN
    SELECT array_agg(mid) INTO v_scope FROM (
      SELECT v_root AS mid
      UNION
      SELECT p.id FROM public.profiles p
       WHERE p.parent_manager_id = v_root AND p.role = 'manager'
    ) t;

    SELECT count(DISTINCT cr.client_id) INTO v_client_total
      FROM public.client_relations cr
     WHERE cr.manager_id = ANY(v_scope) AND cr.status = 'active';
  ELSE
    SELECT count(DISTINCT g.root_manager_id) INTO v_merchant_open
      FROM public.diet_map_grants g
     WHERE g.is_enabled = true
       AND (v_template IS NULL OR g.template_id = v_template);
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (a.record_id)
           a.record_id, a.user_id, a.status, a.type_code
      FROM public.diet_map_assessments a
     WHERE (v_template IS NULL OR a.template_id = v_template)
       AND (
         v_root IS NULL
         OR a.root_manager_id = v_root
         OR (a.root_manager_id IS NULL AND a.manager_id = ANY(v_scope))
       )
     ORDER BY a.record_id, a.submitted_at DESC, a.id DESC
  )
  SELECT
    count(DISTINCT user_id),
    count(*),
    count(*) FILTER (WHERE status = 'scored'),
    count(*) FILTER (WHERE status <> 'scored'),
    COALESCE(jsonb_object_agg(type_code, c) FILTER (WHERE type_code <> ''), '{}'::jsonb)
  INTO v_assessed_clients, v_assessed_records, v_scored, v_pending, v_dist
  FROM (
    SELECT l.user_id, l.status, l.type_code, count(*) OVER (PARTITION BY l.type_code) AS c
      FROM latest l
  ) x;

  v_dist := '{"S":0,"D":0,"G":0,"N":0,"C":0,"A":0}'::jsonb || COALESCE(v_dist, '{}'::jsonb);

  IF v_scope IS NOT NULL THEN
    WITH latest_user AS (
      SELECT DISTINCT ON (a.user_id)
             a.user_id, a.id, a.status, a.type_code, a.submitted_at
        FROM public.diet_map_assessments a
       WHERE (v_template IS NULL OR a.template_id = v_template)
         AND (
           a.root_manager_id = v_root
           OR (a.root_manager_id IS NULL AND a.manager_id = ANY(v_scope))
         )
       ORDER BY a.user_id, a.submitted_at DESC, a.id DESC
    ), page AS (
      SELECT cr.id AS relation_id,
             cr.client_id,
             cr.manager_id,
             COALESCE(NULLIF(btrim(cp.nickname), ''), '未命名客户') AS nickname,
             COALESCE(cp.phone, '') AS phone,
             COALESCE(cp.avatar_url, '') AS avatar_url,
             lu.id AS latest_assessment_id,
             COALESCE(lu.status, '') AS latest_status,
             COALESCE(lu.type_code, '') AS latest_type_code,
             lu.submitted_at AS latest_submitted_at
        FROM public.client_relations cr
        LEFT JOIN public.profiles cp ON cp.id = cr.client_id
        LEFT JOIN latest_user lu ON lu.user_id = cr.client_id
       WHERE cr.manager_id = ANY(v_scope)
         AND cr.status = 'active'
         AND (p_cursor IS NULL OR cr.id > p_cursor)
       ORDER BY cr.id
       LIMIT v_limit
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY page.relation_id), '[]'::jsonb),
           (SELECT pg.relation_id FROM page pg ORDER BY pg.relation_id DESC LIMIT 1)
      INTO v_clients, v_next
      FROM page;

    IF jsonb_array_length(v_clients) < v_limit THEN
      v_next := NULL;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'scope', CASE WHEN v_root IS NULL THEN 'global' ELSE 'merchant' END,
    'root_manager_id', v_root,
    'summary', jsonb_build_object(
      'merchant_open_count', v_merchant_open,
      'client_total', v_client_total,
      'assessed_client_count', COALESCE(v_assessed_clients, 0),
      'assessed_record_count', COALESCE(v_assessed_records, 0),
      'scored_count', COALESCE(v_scored, 0),
      'pending_count', COALESCE(v_pending, 0),
      'type_distribution', v_dist
    ),
    'clients', v_clients,
    'next_cursor', v_next
  );
END;
$function$;