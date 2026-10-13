-- 我的收藏：商品 / 资讯画册 / 课程，按品牌根商户隔离，仅本人可见
CREATE TABLE IF NOT EXISTS public.user_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  brand_root_manager_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  target_type text NOT NULL CHECK (target_type IN ('product','content','manager_course','enterprise_course')),
  target_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_favorites IS '客户收藏。brand_root_manager_id 为 NULL 表示平台品牌，非空表示该商户品牌作用域。';

-- NULL 品牌会绕过普通唯一约束，统一用零 UUID 兜底
CREATE UNIQUE INDEX IF NOT EXISTS user_favorites_unique_target_idx
  ON public.user_favorites (
    user_id,
    COALESCE(brand_root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid),
    target_type,
    target_id
  );

CREATE INDEX IF NOT EXISTS user_favorites_list_idx
  ON public.user_favorites (user_id, brand_root_manager_id, created_at DESC);

ALTER TABLE public.user_favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_favorites_select_own ON public.user_favorites;
CREATE POLICY user_favorites_select_own ON public.user_favorites
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_favorites_insert_own ON public.user_favorites;
CREATE POLICY user_favorites_insert_own ON public.user_favorites
  FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_favorites_delete_own ON public.user_favorites;
CREATE POLICY user_favorites_delete_own ON public.user_favorites
  FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, DELETE ON public.user_favorites TO authenticated;

-- 品牌作用域归一：员工 id 一律收口到企业根商户，避免同一品牌存多条
CREATE OR REPLACE FUNCTION public._favorite_brand_scope(p_brand_manager_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_brand_manager_id IS NULL THEN NULL
    ELSE COALESCE(public.get_enterprise_root_manager_id(p_brand_manager_id), p_brand_manager_id)
  END;
$function$;

-- 目标是否仍然可见（用于收藏时把关 + 列表里判「已失效」）
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
      RETURN FALSE;
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

REVOKE ALL ON FUNCTION public._favorite_brand_scope(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._favorite_target_valid(uuid, uuid, text, uuid) FROM PUBLIC;