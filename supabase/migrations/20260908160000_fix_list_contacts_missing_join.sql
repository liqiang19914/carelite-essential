-- 修复 list_merchant_wecom_contacts 的 count 子查询里 p2.nickname 引用未 JOIN 的 bug
-- 现象：调用 RPC 返回 404 + "missing FROM-clause entry for table \"p2\""
-- 根因：count 子查询引用 p2.nickname，但该子查询从未 LEFT JOIN profiles，p2 别名未定义
-- 修复：给 count 子查询补 LEFT JOIN public.profiles p2 ON p2.id = c.profile_id
--       与主查询（使用 p 别名）保持一致
-- 注意：PostgREST schema 缓存需刷新，下方通过 NOTIFY pgrst 触发
CREATE OR REPLACE FUNCTION public.list_merchant_wecom_contacts(
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0,
  p_search text DEFAULT NULL,
  p_type text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_search text;
  v_type text;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  v_search := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_type := NULLIF(btrim(COALESCE(p_type, '')), '');
  IF v_type IS NOT NULL AND v_type NOT IN ('kf', 'contact') THEN
    RAISE EXCEPTION '好友类型不合法' USING ERRCODE = '22023';
  END IF;

  -- count 子查询补 LEFT JOIN profiles p2，与主查询对齐
  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_contacts c
  LEFT JOIN public.profiles p2 ON p2.id = c.profile_id
  WHERE c.root_manager_id = v_root
    AND (v_type IS NULL OR c.type = v_type)
    AND (
      v_search IS NULL
      OR c.name ILIKE '%' || v_search || '%'
      OR c.external_userid ILIKE '%' || v_search || '%'
      OR COALESCE(c.unionid, '') ILIKE '%' || v_search || '%'
      OR COALESCE(p2.nickname, '') ILIKE '%' || v_search || '%'
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.last_message_at DESC NULLS LAST, row.id), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      c.id,
      c.external_userid,
      c.type,
      COALESCE(c.name, c.external_userid) AS name,
      c.avatar_url,
      c.unionid,
      c.follow_userids,
      c.profile_id,
      p.nickname AS profile_nickname,
      p.phone AS profile_phone,
      c.source_state,
      c.last_message_at,
      c.first_seen_at,
      COALESCE(
        (SELECT jsonb_agg(jsonb_build_object('wecomUserid', s.wecom_userid, 'nickname', s.nickname) ORDER BY s.nickname)
         FROM public.profiles s
         WHERE s.wecom_userid = ANY (c.follow_userids)),
        '[]'::jsonb
      ) AS follow_staff
    FROM public.merchant_wecom_contacts c
    LEFT JOIN public.profiles p ON p.id = c.profile_id
    WHERE c.root_manager_id = v_root
      AND (v_type IS NULL OR c.type = v_type)
      AND (
        v_search IS NULL
        OR c.name ILIKE '%' || v_search || '%'
        OR c.external_userid ILIKE '%' || v_search || '%'
        OR COALESCE(c.unionid, '') ILIKE '%' || v_search || '%'
        OR COALESCE(p.nickname, '') ILIKE '%' || v_search || '%'
      )
    ORDER BY c.last_message_at DESC NULLS LAST, c.id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_contacts(int, int, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_contacts(int, int, text, text) TO authenticated;

-- 刷新 PostgREST schema 缓存，让 RPC 立即生效
NOTIFY pgrst, 'reload schema';
