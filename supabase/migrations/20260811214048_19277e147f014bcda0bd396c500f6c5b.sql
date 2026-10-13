-- 列出所有「同一手机号却有多个账号」的人，附活动摘要与推荐保留项，供后台合并界面使用
CREATE OR REPLACE FUNCTION public.list_duplicate_phone_accounts()
RETURNS TABLE (
  phone text,
  account_id uuid,
  nickname text,
  real_name text,
  created_at timestamptz,
  records int,
  measures int,
  order_count int,
  points int,
  merchants int,
  merchant_names text,
  recommended boolean
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.is_admin((SELECT auth.uid())) THEN
    RAISE EXCEPTION '只有平台管理员可以查看重复账号清单' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH norm AS (
    SELECT p.id, p.nickname, p.real_name, p.created_at,
           public.normalize_cn_phone(p.phone) AS ph
    FROM public.profiles p
    WHERE public.normalize_cn_phone(p.phone) <> ''
      AND p.role::text = 'user'
  ),
  dup AS (
    SELECT n.ph FROM norm n GROUP BY n.ph HAVING count(*) > 1
  ),
  acc AS (
    SELECT n.id, n.nickname, n.real_name, n.created_at, n.ph,
      (SELECT count(*) FROM public.health_records hr WHERE hr.user_id = n.id)::int AS records,
      (SELECT count(*) FROM public.body_compositions bc
         JOIN public.health_records hr2 ON hr2.id = bc.record_id
        WHERE hr2.user_id = n.id)::int AS measures,
      (SELECT count(*) FROM public.orders o WHERE o.user_id = n.id)::int AS order_count,
      COALESCE((SELECT pb.balance FROM public.points_balances pb WHERE pb.user_id = n.id), 0)::int AS points,
      (SELECT count(*) FROM public.client_relations cr
        WHERE cr.client_id = n.id AND cr.status = 'active')::int AS merchants,
      (SELECT string_agg(COALESCE(NULLIF(btrim(mp.real_name), ''), mp.nickname, '未命名商户'), '、')
         FROM public.client_relations cr2
         JOIN public.profiles mp ON mp.id = cr2.manager_id
        WHERE cr2.client_id = n.id AND cr2.status = 'active') AS merchant_names
    FROM norm n JOIN dup ON dup.ph = n.ph
  )
  SELECT a.ph, a.id, a.nickname, a.real_name, a.created_at,
         a.records, a.measures, a.order_count, a.points, a.merchants, a.merchant_names,
         (a.id = first_value(a.id) OVER (
            PARTITION BY a.ph
            ORDER BY (a.records + a.measures + a.order_count + a.points) DESC, a.created_at ASC
         )) AS recommended
  FROM acc a
  ORDER BY a.ph, a.created_at;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_duplicate_phone_accounts() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_duplicate_phone_accounts() TO authenticated, service_role;