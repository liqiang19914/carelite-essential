-- 修复商户端饮食导图覆盖率取数：Postgres 没有 max(uuid) 聚合，
-- 原实现 (SELECT max(relation_id) FROM page) 会让整个 RPC 抛 42883，
-- 商户端因此永远拿不到客户名单（前端把报错渲染成「本店还没有客户」）。
-- 改为按 relation_id 倒序取本页最后一行；因分页是 ORDER BY cr.id 升序，语义等价。
-- 其余权限分支、1–50 条限制、不足一页清空 next cursor、升序分页协议全部原样保留。
CREATE OR REPLACE FUNCTION public.get_diet_map_coverage(
  p_template_id uuid DEFAULT NULL,
  p_root_manager_id uuid DEFAULT NULL,
  p_cursor uuid DEFAULT NULL,
  p_limit int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_scope uuid[];
  v_limit int;
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
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_uid);
    IF v_root IS NULL THEN
      RAISE EXCEPTION '仅平台管理员或健康管理师可查看覆盖情况' USING ERRCODE = '42501';
    END IF;
    IF p_root_manager_id IS NOT NULL AND p_root_manager_id <> v_root THEN
      RAISE EXCEPTION '只能查看本企业的覆盖情况' USING ERRCODE = '42501';
    END IF;
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
       AND (p_template_id IS NULL OR g.template_id = p_template_id);
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (a.record_id)
           a.record_id, a.user_id, a.status, a.type_code
      FROM public.diet_map_assessments a
     WHERE (p_template_id IS NULL OR a.template_id = p_template_id)
       AND (v_scope IS NULL OR a.manager_id = ANY(v_scope))
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
       WHERE (p_template_id IS NULL OR a.template_id = p_template_id)
         AND a.manager_id = ANY(v_scope)
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
$$;

REVOKE ALL ON FUNCTION public.get_diet_map_coverage(uuid, uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_diet_map_coverage(uuid, uuid, uuid, int) TO authenticated;

COMMENT ON FUNCTION public.get_diet_map_coverage(uuid, uuid, uuid, int) IS
  '饮食导图覆盖情况：平台端不传 root 时返回全局摘要，商户端强制按本企业根 + 名下员工统计并分页返回 active 客户。分页按 client_relations.id 升序、游标为本页最后一个 id（不足一页则无下一页）。';