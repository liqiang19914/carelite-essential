-- 商户端首页客户概览统计：服务端一次聚合，突破列表 100 条上限。
-- 成员口径与去重顺序与 get_enterprise_clients_with_owner 完全一致。
CREATE OR REPLACE FUNCTION public.get_manager_dashboard_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_total bigint;
  v_month_new bigint;
  v_active_30 bigint;
  v_within_7 bigint;
  v_pending_7 bigint;
  v_never bigint;
  v_trend jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  WITH members AS (
    SELECT v_root AS mid
    UNION
    SELECT p.id
    FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  deduplicated AS (
    SELECT DISTINCT ON (cr.client_id)
      cr.client_id,
      cr.last_contact_at,
      cr.created_at AS relation_created_at
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
    ORDER BY
      cr.client_id,
      (cr.status = 'active') DESC,
      cr.updated_at DESC NULLS LAST,
      cr.created_at DESC,
      cr.id DESC
  ),
  aggregates AS (
    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (
        WHERE (relation_created_at AT TIME ZONE 'Asia/Shanghai')::date
          >= date_trunc('month', (now() AT TIME ZONE 'Asia/Shanghai'))::date
      ) AS month_new,
      COUNT(*) FILTER (WHERE last_contact_at >= now() - interval '30 days') AS active_30,
      COUNT(*) FILTER (WHERE last_contact_at >= now() - interval '7 days') AS within_7,
      COUNT(*) FILTER (
        WHERE last_contact_at IS NULL OR last_contact_at < now() - interval '7 days'
      ) AS pending_7,
      COUNT(*) FILTER (WHERE last_contact_at IS NULL) AS never
    FROM deduplicated
  ),
  trend AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('key', d.key, 'count', COALESCE(d.cnt, 0))
      ORDER BY d.key
    ), '[]'::jsonb) AS data
    FROM (
      SELECT to_char((now() AT TIME ZONE 'Asia/Shanghai')::date - i, 'YYYY-MM-DD') AS key,
             COUNT(dd.client_id) AS cnt
      FROM generate_series(13, 0, -1) AS i
      LEFT JOIN deduplicated dd
        ON (dd.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date
           = (now() AT TIME ZONE 'Asia/Shanghai')::date - i
      GROUP BY i
      ORDER BY i DESC
    ) d
  )
  SELECT a.total, a.month_new, a.active_30, a.within_7, a.pending_7, a.never, t.data
  INTO v_total, v_month_new, v_active_30, v_within_7, v_pending_7, v_never, v_trend
  FROM aggregates a
  CROSS JOIN trend t;

  RETURN jsonb_build_object(
    'total', COALESCE(v_total, 0),
    'month_new', COALESCE(v_month_new, 0),
    'active_30', COALESCE(v_active_30, 0),
    'within_7', COALESCE(v_within_7, 0),
    'pending_7', COALESCE(v_pending_7, 0),
    'never', COALESCE(v_never, 0),
    'trend', COALESCE(v_trend, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_manager_dashboard_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_dashboard_stats() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_manager_dashboard_stats() FROM anon;

-- 客户详情「归属记录」判权放宽：从「盖章行存在」改为「企业成员集合内存在任意关系」，
-- 历史查询兼容 root_manager_id 为空的存量行。
CREATE OR REPLACE FUNCTION public.get_client_assignment_history(p_client_id uuid)
RETURNS TABLE (
  id uuid,
  from_manager_id uuid,
  from_name text,
  to_manager_id uuid,
  to_name text,
  operated_by uuid,
  operator_name text,
  reason text,
  customer_name_snapshot text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_root uuid;
  v_has_relation boolean;
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager_id);

  SELECT EXISTS (
    SELECT 1 FROM public.client_relations cr
    WHERE cr.client_id = p_client_id
      AND cr.manager_id IN (
        SELECT v_root AS mid
        UNION
        SELECT p.id FROM public.profiles p
        WHERE p.parent_manager_id = v_root AND p.role = 'manager'
      )
  ) INTO v_has_relation;

  IF NOT v_has_relation THEN
    RAISE EXCEPTION '无权查看该客户的归属历史' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT h.id,
         h.from_manager_id,
         COALESCE(fp.nickname, ''::text),
         h.to_manager_id,
         COALESCE(tp.nickname, ''::text),
         h.operated_by,
         COALESCE(op.nickname, ''::text),
         COALESCE(h.reason, ''::text),
         COALESCE(h.customer_name_snapshot, ''::text),
         h.created_at
  FROM public.client_assignment_history h
  LEFT JOIN public.profiles fp ON fp.id = h.from_manager_id
  LEFT JOIN public.profiles tp ON tp.id = h.to_manager_id
  LEFT JOIN public.profiles op ON op.id = h.operated_by
  WHERE h.client_id = p_client_id
    AND (h.root_manager_id = v_root OR h.root_manager_id IS NULL)
  ORDER BY h.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_client_assignment_history(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_client_assignment_history(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_assignment_history(uuid) FROM anon;