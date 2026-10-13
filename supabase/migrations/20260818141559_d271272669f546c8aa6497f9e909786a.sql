-- 平台品牌（brand_root 为空）下也允许收藏商户课程/内容：
-- 只校验目标自身是否仍在线，品牌作用域校验仅在指定品牌时生效。
CREATE OR REPLACE FUNCTION public._favorite_target_valid(
  p_user_id uuid,
  p_brand_root uuid,
  p_target_type text,
  p_target_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_eid uuid;
BEGIN
  IF p_user_id IS NULL OR p_target_id IS NULL OR p_target_type IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_target_type = 'product' THEN
    RETURN public.can_view_product(p_target_id, p_user_id);
  END IF;

  IF p_target_type = 'content' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.manager_content_items ci
      WHERE ci.id = p_target_id
        AND ci.is_published = TRUE
        AND ci.moderation_status = 'passed'
        AND (p_brand_root IS NULL OR ci.root_manager_id = p_brand_root)
    );
  END IF;

  IF p_target_type = 'manager_course' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.manager_courses mc
      WHERE mc.id = p_target_id
        AND mc.is_published = TRUE
        AND mc.review_status = 'approved'
        AND (
          p_brand_root IS NULL
          OR public.get_enterprise_root_manager_id(mc.manager_id) = p_brand_root
        )
        AND (
          COALESCE(mc.visibility, 'public') <> 'clients_only'
          OR EXISTS (
            SELECT 1 FROM public.client_relations cr
            WHERE cr.client_id = p_user_id
              AND cr.manager_id = mc.manager_id
              AND cr.status = 'active'
          )
        )
    );
  END IF;

  IF p_target_type = 'enterprise_course' THEN
    IF p_brand_root IS NULL THEN
      RETURN EXISTS (
        SELECT 1 FROM public.enterprise_courses ec
        WHERE ec.id = p_target_id AND ec.is_published = TRUE
      );
    END IF;
    v_eid := public.get_profile_enterprise_id(p_brand_root);
    IF v_eid IS NULL THEN
      RETURN FALSE;
    END IF;
    RETURN EXISTS (
      SELECT 1 FROM public.enterprise_courses ec
      WHERE ec.id = p_target_id
        AND ec.is_published = TRUE
        AND ec.enterprise_id = v_eid
    );
  END IF;

  RETURN FALSE;
END;
$function$;

REVOKE ALL ON FUNCTION public._favorite_target_valid(uuid, uuid, text, uuid) FROM PUBLIC, anon;