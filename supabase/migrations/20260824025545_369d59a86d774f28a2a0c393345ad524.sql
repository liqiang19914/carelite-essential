-- feature 289：后台权限三项修复
-- 1) 客户敏感数据三层闸门补齐角色层：module_open_for_client 加角色勾选校验（owner 恒真），六张表一起收口
CREATE OR REPLACE FUNCTION public.module_open_for_client(p_client_id uuid, p_module_key text)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.client_relations cr
    JOIN public.merchant_module_grants g
      ON g.manager_id = public.get_enterprise_root_manager_id(cr.manager_id)
     AND g.module_key = p_module_key
     AND g.grant_status = 'granted'
     AND g.is_enabled = true
    WHERE cr.client_id = p_client_id
      AND cr.status = 'active'
      AND (
        cr.manager_id = (SELECT auth.uid())
        OR public.is_enterprise_member_for_admin(cr.manager_id, (SELECT auth.uid()))
      )
  )
  AND public.has_enterprise_permission(
    CASE p_module_key
      WHEN 'view_health_records'  THEN 'view_health_records'
      WHEN 'view_health_insights' THEN 'health_insights'
      WHEN 'view_conversations'   THEN 'conversations'
      ELSE p_module_key
    END,
    (SELECT auth.uid())
  );
$function$;

-- 2) 商户端健康洞察分页 RPC：企业根范围 + 角色闸门 + 三层可见性 + 关键词/严重程度筛选
CREATE OR REPLACE FUNCTION public.list_manager_health_insights(
  p_keyword text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 10
)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  category text,
  title text,
  content text,
  severity text,
  source_type text,
  source_snippet text,
  analyzed_at timestamptz,
  client_nickname text,
  total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_limit int;
  v_offset int;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('health_insights', v_uid) THEN
    RAISE EXCEPTION '你的角色未获授「查看健康洞察」，请联系超级管理员在企业中心勾选' USING ERRCODE = '42501';
  END IF;
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    RETURN;
  END IF;
  SELECT public.is_enterprise_admin(v_uid) INTO v_is_admin;
  v_limit := LEAST(GREATEST(COALESCE(p_page_size, 10), 1), 50);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  RETURN QUERY
  WITH visible AS (
    SELECT DISTINCT cr.client_id
    FROM public.client_relations cr
    WHERE cr.status = 'active'
      AND (v_is_admin OR cr.manager_id = v_uid)
      AND (cr.manager_id = v_uid
           OR cr.manager_id IN (
             SELECT p.id FROM public.profiles p
             WHERE p.parent_manager_id = v_root AND p.role = 'manager'
           )
           OR cr.manager_id = v_root)
      AND public.can_manager_view_client_data(cr.client_id, 'view_health_insights')
  ),
  filtered AS (
    SELECT hi.*, cp.nickname AS client_nickname
    FROM public.health_insights hi
    JOIN visible v ON v.client_id = hi.user_id
    LEFT JOIN public.profiles cp ON cp.id = hi.user_id
    WHERE (p_severity IS NULL OR p_severity = '' OR hi.severity = p_severity)
      AND (
        v_keyword IS NULL
        OR hi.title ILIKE '%' || v_keyword || '%'
        OR hi.content ILIKE '%' || v_keyword || '%'
        OR COALESCE(cp.nickname, '') ILIKE '%' || v_keyword || '%'
      )
  )
  SELECT f.id,
         f.user_id,
         f.category,
         f.title,
         f.content,
         f.severity,
         f.source_type,
         f.source_snippet,
         f.analyzed_at,
         f.client_nickname,
         COUNT(*) OVER() AS total_count
  FROM filtered f
  ORDER BY f.analyzed_at DESC, f.id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights(text, text, int, int) TO authenticated;

-- 3) 平台端健康洞察用户分页 RPC：商户根筛选 + 关键词 + 洞察统计
CREATE OR REPLACE FUNCTION public.admin_list_health_insight_users(
  p_merchant_root uuid DEFAULT NULL,
  p_keyword text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS TABLE(
  id uuid,
  nickname text,
  phone text,
  last_analyzed_at timestamptz,
  insight_count bigint,
  critical_count bigint,
  total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit int;
  v_offset int;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可访问' USING ERRCODE = '42501';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  RETURN QUERY
  SELECT u.id,
         COALESCE(u.nickname, '')::text,
         u.phone,
         agg.last_analyzed_at,
         COALESCE(agg.insight_count, 0)::bigint,
         COALESCE(agg.critical_count, 0)::bigint,
         COUNT(*) OVER() AS total_count
  FROM public.profiles u
  LEFT JOIN (
    SELECT hi.user_id,
           MAX(hi.analyzed_at) AS last_analyzed_at,
           COUNT(*) AS insight_count,
           COUNT(*) FILTER (WHERE hi.severity = 'critical') AS critical_count
    FROM public.health_insights hi
    GROUP BY hi.user_id
  ) agg ON agg.user_id = u.id
  WHERE u.role = 'user'
    AND (
      p_merchant_root IS NULL
      OR EXISTS (
        SELECT 1 FROM public.client_relations cr
        WHERE cr.client_id = u.id
          AND cr.status = 'active'
          AND public.get_enterprise_root_manager_id(cr.manager_id) = p_merchant_root
      )
    )
    AND (
      v_keyword IS NULL
      OR COALESCE(u.nickname, '') ILIKE '%' || v_keyword || '%'
      OR COALESCE(u.phone, '') ILIKE '%' || v_keyword || '%'
    )
  ORDER BY COALESCE(agg.critical_count, 0) DESC,
           COALESCE(agg.insight_count, 0) DESC,
           agg.last_analyzed_at DESC NULLS LAST,
           u.created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_health_insight_users(uuid, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_health_insight_users(uuid, text, int, int) TO authenticated;

-- 4) 平台端指定用户洞察分页 RPC
CREATE OR REPLACE FUNCTION public.admin_list_health_insights(
  p_user_id uuid,
  p_keyword text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  category text,
  title text,
  content text,
  severity text,
  source_type text,
  source_snippet text,
  analyzed_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit int;
  v_offset int;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可访问' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  RETURN QUERY
  SELECT hi.id,
         hi.user_id,
         hi.category,
         hi.title,
         hi.content,
         hi.severity,
         hi.source_type,
         hi.source_snippet,
         hi.analyzed_at,
         COUNT(*) OVER() AS total_count
  FROM public.health_insights hi
  WHERE hi.user_id = p_user_id
    AND (p_severity IS NULL OR p_severity = '' OR hi.severity = p_severity)
    AND (
      v_keyword IS NULL
      OR hi.title ILIKE '%' || v_keyword || '%'
      OR hi.content ILIKE '%' || v_keyword || '%'
    )
  ORDER BY hi.analyzed_at DESC, hi.id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_health_insights(uuid, text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_health_insights(uuid, text, text, int, int) TO authenticated;

-- 5) 代编辑他人智能体：白名单补头像字段（此前头像 patch 被静默忽略，前端却提示已保存）
CREATE OR REPLACE FUNCTION public.update_target_manager_card(
  p_target_manager_id uuid,
  p_patch jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '请先登录';
  END IF;
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION '没有要保存的内容';
  END IF;
  IF NOT can_manage_target_manager_card(v_caller, p_target_manager_id, 'agent_edit') THEN
    RAISE EXCEPTION '无权限编辑该员工的智能体，请联系超级管理员在「企业中心 → 角色权限」里勾选';
  END IF;

  UPDATE managers m
     SET tagline = CASE WHEN p_patch ? 'tagline'
                        THEN nullif(p_patch->>'tagline', '') ELSE m.tagline END,
         intro_personal = CASE WHEN p_patch ? 'intro_personal'
                        THEN nullif(p_patch->>'intro_personal', '') ELSE m.intro_personal END,
         intro_company = CASE WHEN p_patch ? 'intro_company'
                        THEN nullif(p_patch->>'intro_company', '') ELSE m.intro_company END,
         company_name = CASE WHEN p_patch ? 'company_name'
                        THEN nullif(p_patch->>'company_name', '') ELSE m.company_name END,
         public_contact_phone = CASE WHEN p_patch ? 'public_contact_phone'
                        THEN nullif(p_patch->>'public_contact_phone', '') ELSE m.public_contact_phone END,
         digital_avatar_image_url = CASE WHEN p_patch ? 'digital_avatar_image_url'
                        THEN nullif(p_patch->>'digital_avatar_image_url', '') ELSE m.digital_avatar_image_url END,
         credentials = CASE WHEN p_patch ? 'credentials'
                        THEN (
                          SELECT coalesce(array_agg(x.v ORDER BY x.ord), '{}'::text[])
                            FROM jsonb_array_elements_text(
                                   CASE WHEN jsonb_typeof(p_patch->'credentials') = 'array'
                                        THEN p_patch->'credentials' ELSE '[]'::jsonb END
                                 ) WITH ordinality AS x(v, ord)
                        )
                        ELSE m.credentials END,
         featured_product_ids = CASE WHEN p_patch ? 'featured_product_ids'
                        THEN (
                          SELECT coalesce(array_agg(x.v::uuid ORDER BY x.ord), '{}'::uuid[])
                            FROM jsonb_array_elements_text(
                                   CASE WHEN jsonb_typeof(p_patch->'featured_product_ids') = 'array'
                                        THEN p_patch->'featured_product_ids' ELSE '[]'::jsonb END
                                 ) WITH ordinality AS x(v, ord)
                        )
                        ELSE m.featured_product_ids END,
         updated_at = now()
   WHERE m.id = p_target_manager_id
   RETURNING m.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION '该员工的健管师档案不存在，保存失败';
  END IF;
  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.update_target_manager_card(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_target_manager_card(uuid, jsonb) TO authenticated;

-- 6) 企业 ID 一致性修复：仅修可唯一确定的错位行（员工对齐企业主；managers 对齐同 id 的 profiles）
UPDATE public.profiles p
   SET enterprise_id = b.enterprise_id
  FROM public.profiles b
 WHERE p.role = 'manager'
   AND p.parent_manager_id = b.id
   AND b.role = 'manager'
   AND b.parent_manager_id IS NULL
   AND b.enterprise_id IS NOT NULL
   AND p.enterprise_id IS DISTINCT FROM b.enterprise_id;

UPDATE public.managers m
   SET enterprise_id = p.enterprise_id
  FROM public.profiles p
 WHERE p.id = m.id
   AND p.role = 'manager'
   AND p.enterprise_id IS NOT NULL
   AND m.enterprise_id IS DISTINCT FROM p.enterprise_id;