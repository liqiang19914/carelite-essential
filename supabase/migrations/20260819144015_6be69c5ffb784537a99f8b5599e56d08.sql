-- ============================================================
-- 商户免审直发 + 按店隔离 + 进店即客户（Feature 194）
--
-- 1. manager_create_product / manager_update_product：允许 active 状态
-- 2. products RLS：manager INSERT/UPDATE 允许 active
-- 3. _can_order_product_in_shop：商户店上下文拒绝平台商品下单
-- 4. get_manager_clients / get_enterprise_clients_with_owner：UNION shop_members
-- ============================================================

-- ── 1a. manager_create_product：允许 active ──────────────────
CREATE OR REPLACE FUNCTION public.manager_create_product(
  p_title           text,
  p_subtitle        text    DEFAULT ''::text,
  p_description     text    DEFAULT ''::text,
  p_cover_image_url text    DEFAULT ''::text,
  p_cover_images    jsonb   DEFAULT NULL::jsonb,
  p_gallery_images  jsonb   DEFAULT '[]'::jsonb,
  p_category        text    DEFAULT 'general'::text,
  p_tags            text[]  DEFAULT '{}'::text[],
  p_status          text    DEFAULT 'draft'::text,
  p_sort_weight     integer DEFAULT 0,
  p_sale_mode       text    DEFAULT 'cash'::text,
  p_description_doc jsonb   DEFAULT NULL::jsonb
)
RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          UUID := auth.uid();
  v_role         TEXT;
  v_disabled     BOOLEAN;
  v_title        TEXT;
  v_status       TEXT;
  v_cover_images JSONB;
  v_sale_mode    TEXT;
  v_row          products;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT role::text, COALESCE(is_disabled, false)
    INTO v_role, v_disabled
  FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden: profile missing';
  END IF;
  IF v_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'forbidden: manager role required';
  END IF;
  IF v_disabled THEN
    RAISE EXCEPTION 'forbidden: account disabled';
  END IF;

  v_title := btrim(COALESCE(p_title, ''));
  IF v_title = '' THEN
    RAISE EXCEPTION 'product title required';
  END IF;
  IF char_length(v_title) > 200 THEN
    RAISE EXCEPTION 'product title too long (max 200)';
  END IF;

  v_status := COALESCE(NULLIF(btrim(COALESCE(p_status, '')), ''), 'draft');
  IF v_status NOT IN ('draft', 'pending_review', 'active') THEN
    RAISE EXCEPTION 'invalid manager status: %', v_status;
  END IF;

  v_sale_mode := COALESCE(NULLIF(btrim(COALESCE(p_sale_mode, '')), ''), 'cash');
  IF v_sale_mode NOT IN ('cash', 'points') THEN
    RAISE EXCEPTION 'invalid sale_mode: %', v_sale_mode;
  END IF;

  IF p_cover_images IS NOT NULL AND jsonb_typeof(p_cover_images) = 'array' THEN
    IF jsonb_array_length(p_cover_images) > 4 THEN
      RAISE EXCEPTION 'cover_images can contain at most 4 entries';
    END IF;
    v_cover_images := p_cover_images;
  ELSIF COALESCE(p_cover_image_url, '') <> '' THEN
    v_cover_images := jsonb_build_array(p_cover_image_url);
  ELSE
    v_cover_images := '[]'::jsonb;
  END IF;

  INSERT INTO products (
    source_type, owner_manager_id, title, subtitle, description,
    cover_image_url, cover_images, gallery_images, category, tags,
    status, is_featured, sort_weight, created_by, sale_mode,
    description_doc
  ) VALUES (
    'manager', v_uid, v_title,
    COALESCE(p_subtitle, ''), COALESCE(p_description, ''),
    COALESCE(p_cover_image_url, ''), v_cover_images,
    COALESCE(p_gallery_images, '[]'::jsonb),
    COALESCE(NULLIF(btrim(COALESCE(p_category, '')), ''), 'general'),
    COALESCE(p_tags, '{}'::text[]),
    v_status, false, COALESCE(p_sort_weight, 0), v_uid,
    v_sale_mode,
    p_description_doc
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- ── 1b. manager_update_product：允许 active + 简化状态机 ─────
CREATE OR REPLACE FUNCTION public.manager_update_product(
  p_id              uuid,
  p_patch           jsonb,
  p_expected_status text[] DEFAULT NULL
)
RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid         UUID := auth.uid();
  v_role        TEXT;
  v_disabled    BOOLEAN;
  v_owner       UUID;
  v_source      TEXT;
  v_cur_status  TEXT;
  v_title       TEXT;
  v_status      TEXT;
  v_sale_mode   TEXT;
  v_cover       JSONB;
  v_unknown_key TEXT;
  v_row         products;
  v_allowed     CONSTANT TEXT[] := ARRAY[
    'title', 'subtitle', 'description',
    'cover_image_url', 'cover_images', 'gallery_images',
    'category', 'tags',
    'status', 'sort_weight', 'sale_mode',
    'description_doc'
  ];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT role::text, COALESCE(is_disabled, false)
    INTO v_role, v_disabled
  FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden: profile missing';
  END IF;
  IF v_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'forbidden: manager role required';
  END IF;
  IF v_disabled THEN
    RAISE EXCEPTION 'forbidden: account disabled';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'patch must be a json object';
  END IF;

  SELECT k INTO v_unknown_key
  FROM jsonb_object_keys(p_patch) AS k
  WHERE k <> ALL(v_allowed)
  LIMIT 1;
  IF v_unknown_key IS NOT NULL THEN
    RAISE EXCEPTION 'unknown patch key: %', v_unknown_key;
  END IF;

  SELECT source_type, owner_manager_id, status
    INTO v_source, v_owner, v_cur_status
  FROM products WHERE id = p_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_source <> 'manager' OR v_owner IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'forbidden: not product owner';
  END IF;

  IF p_expected_status IS NOT NULL
     AND array_length(p_expected_status, 1) > 0
     AND NOT (v_cur_status = ANY(p_expected_status)) THEN
    RAISE EXCEPTION 'product status changed';
  END IF;

  IF p_patch ? 'title' THEN
    v_title := btrim(COALESCE(p_patch->>'title', ''));
    IF v_title = '' THEN
      RAISE EXCEPTION 'product title required';
    END IF;
    IF char_length(v_title) > 200 THEN
      RAISE EXCEPTION 'product title too long (max 200)';
    END IF;
  END IF;

  IF p_patch ? 'status' THEN
    v_status := btrim(COALESCE(p_patch->>'status', ''));
    IF v_status NOT IN ('draft', 'pending_review', 'active', 'archived') THEN
      RAISE EXCEPTION 'invalid manager status: %', v_status;
    END IF;
  END IF;

  IF p_patch ? 'sale_mode' THEN
    v_sale_mode := btrim(COALESCE(p_patch->>'sale_mode', ''));
    IF v_sale_mode NOT IN ('cash', 'points') THEN
      RAISE EXCEPTION 'invalid sale_mode: %', v_sale_mode;
    END IF;
  END IF;

  IF p_patch ? 'cover_images' THEN
    v_cover := p_patch->'cover_images';
    IF jsonb_typeof(v_cover) <> 'array' THEN
      RAISE EXCEPTION 'cover_images must be a JSON array';
    END IF;
    IF jsonb_array_length(v_cover) > 4 THEN
      RAISE EXCEPTION 'cover_images can contain at most 4 entries';
    END IF;
  END IF;

  UPDATE products SET
    title           = CASE WHEN p_patch ? 'title'           THEN btrim(p_patch->>'title')                        ELSE title END,
    subtitle        = CASE WHEN p_patch ? 'subtitle'        THEN COALESCE(p_patch->>'subtitle', '')               ELSE subtitle END,
    description     = CASE WHEN p_patch ? 'description'     THEN COALESCE(p_patch->>'description', '')            ELSE description END,
    description_doc = CASE WHEN p_patch ? 'description_doc' THEN p_patch->'description_doc'                       ELSE description_doc END,
    cover_image_url = CASE WHEN p_patch ? 'cover_image_url' THEN COALESCE(p_patch->>'cover_image_url', '')        ELSE cover_image_url END,
    cover_images    = CASE WHEN p_patch ? 'cover_images'    THEN COALESCE(p_patch->'cover_images', '[]'::jsonb)   ELSE cover_images END,
    gallery_images  = CASE WHEN p_patch ? 'gallery_images'  THEN COALESCE(p_patch->'gallery_images', '[]'::jsonb) ELSE gallery_images END,
    category        = CASE WHEN p_patch ? 'category'        THEN COALESCE(NULLIF(btrim(p_patch->>'category'), ''), 'general') ELSE category END,
    tags            = CASE WHEN p_patch ? 'tags' THEN COALESCE(
                            ARRAY(SELECT jsonb_array_elements_text(p_patch->'tags')),
                            '{}'::text[]
                          ) ELSE tags END,
    status          = CASE WHEN p_patch ? 'status'      THEN btrim(p_patch->>'status')                            ELSE status END,
    sort_weight     = CASE WHEN p_patch ? 'sort_weight' THEN COALESCE((p_patch->>'sort_weight')::integer, sort_weight) ELSE sort_weight END,
    sale_mode       = CASE WHEN p_patch ? 'sale_mode'   THEN btrim(p_patch->>'sale_mode')                         ELSE sale_mode END
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- ── 2. products RLS：manager INSERT/UPDATE 允许 active ──────
DROP POLICY IF EXISTS "products_manager_insert_own" ON products;
CREATE POLICY "products_manager_insert_own"
  ON products FOR INSERT
  WITH CHECK (
    public.is_manager(auth.uid())
    AND source_type = 'manager'
    AND owner_manager_id = auth.uid()
    AND created_by = auth.uid()
    AND is_featured = false
    AND status IN ('draft', 'pending_review', 'active')
  );

DROP POLICY IF EXISTS "products_manager_update_own" ON products;
CREATE POLICY "products_manager_update_own"
  ON products FOR UPDATE
  USING (
    source_type = 'manager'
    AND owner_manager_id = auth.uid()
  )
  WITH CHECK (
    source_type = 'manager'
    AND owner_manager_id = auth.uid()
    AND is_featured = false
    AND status IN ('draft', 'pending_review', 'active', 'archived')
  );

-- ── 3. _can_order_product_in_shop：商户店上下文拒绝平台商品 ──
CREATE OR REPLACE FUNCTION public._can_order_product_in_shop(
  p_product_id uuid,
  p_user_id uuid,
  p_shop_root uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product public.products;
  v_product_root uuid;
BEGIN
  IF NOT public.can_view_product(p_product_id, p_user_id) THEN
    RETURN false;
  END IF;
  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF v_product.id IS NULL THEN
    RETURN false;
  END IF;
  -- 平台商品只在平台主端（无 shop 上下文）可买；商户店内不可下单
  IF v_product.source_type = 'platform' THEN
    RETURN p_shop_root IS NULL;
  END IF;
  v_product_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  IF p_shop_root IS NULL THEN
    RETURN false;
  END IF;
  RETURN v_product_root IS NOT NULL AND v_product_root = p_shop_root;
END;
$function$;

-- ── 4a. get_manager_clients：UNION shop_members ──────────────
DROP FUNCTION IF EXISTS public.get_manager_clients(uuid);
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH authorized AS (
    SELECT 1
    WHERE auth.uid() = p_manager_id
       OR is_admin(auth.uid())
       OR is_enterprise_member_for_admin(p_manager_id, auth.uid())
  ),
  root_id AS (
    SELECT public.get_enterprise_root_manager_id(p_manager_id) AS rid
  ),
  -- 已有归属关系的客户
  relation_rows AS (
    SELECT
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at
    FROM client_relations cr
    WHERE cr.manager_id = p_manager_id
  ),
  -- 仅进店（shop_members）但无归属关系的客户
  member_only_rows AS (
    SELECT
      sm.id AS relation_id,
      sm.client_id,
      'active'::text AS status,
      ''::text AS notes,
      NULL::timestamptz AS last_contact_at,
      sm.first_entered_at AS relation_created_at
    FROM shop_members sm
    WHERE sm.root_manager_id = (SELECT rid FROM root_id)
      AND sm.client_id NOT IN (SELECT r.client_id FROM relation_rows r)
  ),
  combined AS (
    SELECT * FROM relation_rows
    UNION ALL
    SELECT * FROM member_only_rows
  )
  SELECT
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    p.nickname::text,
    CASE
      WHEN public.can_manager_view_client_category(c.client_id, 'show_phone')
        THEN p.phone::text
      ELSE NULL
    END AS phone,
    p.avatar_url,
    COALESCE(p.privacy_settings, '{}'::jsonb) AS privacy_settings,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at
  FROM combined c
  CROSS JOIN authorized
  LEFT JOIN profiles p ON p.id = c.client_id
  LEFT JOIN shop_members sm
    ON sm.root_manager_id = (SELECT rid FROM root_id)
   AND sm.client_id = c.client_id
  ORDER BY c.relation_created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO service_role;

-- ── 4b. get_enterprise_clients_with_owner：UNION shop_members ─
DROP FUNCTION IF EXISTS public.get_enterprise_clients_with_owner(integer, integer, text, uuid);
CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL::text,
  p_owner_manager_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  owner_manager_id uuid,
  owner_manager_nickname text,
  owner_manager_phone text,
  owner_sub_role text,
  owner_is_disabled boolean,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT public.is_enterprise_admin(v_uid) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    RETURN;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

  RETURN QUERY
  WITH members AS (
    SELECT v_root AS mid
    UNION
    SELECT p.id
    FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  -- 已有归属关系的客户
  relation_scoped AS (
    SELECT
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text AS status,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.manager_id AS owner_manager_id
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
      AND (p_owner_manager_id IS NULL OR cr.manager_id = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = cr.client_id
            AND (cp.nickname ILIKE '%' || v_search || '%'
                 OR cp.phone ILIKE '%' || v_search || '%')
        )
      )
  ),
  -- 仅进店（shop_members）但无归属关系的客户
  member_only AS (
    SELECT
      sm.id AS relation_id,
      sm.client_id,
      'active'::text AS status,
      ''::text AS notes,
      NULL::timestamptz AS last_contact_at,
      sm.first_entered_at AS relation_created_at,
      v_root AS owner_manager_id
    FROM public.shop_members sm
    WHERE sm.root_manager_id = v_root
      AND sm.client_id NOT IN (SELECT r.client_id FROM relation_scoped r)
      AND (p_owner_manager_id IS NULL OR v_root = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = sm.client_id
            AND (cp.nickname ILIKE '%' || v_search || '%'
                 OR cp.phone ILIKE '%' || v_search || '%')
        )
      )
  ),
  combined AS (
    SELECT * FROM relation_scoped
    UNION ALL
    SELECT * FROM member_only
  )
  SELECT
    s.relation_id,
    s.client_id,
    s.status,
    s.notes,
    s.last_contact_at,
    s.relation_created_at,
    cp.nickname::text,
    CASE
      WHEN public.can_manager_view_client_category(s.client_id, 'show_phone')
        THEN cp.phone::text
      ELSE NULL
    END AS phone,
    cp.avatar_url,
    COALESCE(cp.privacy_settings, '{}'::jsonb) AS privacy_settings,
    s.owner_manager_id,
    op.nickname::text AS owner_manager_nickname,
    op.phone::text AS owner_manager_phone,
    COALESCE(op.sub_role, '')::text AS owner_sub_role,
    COALESCE(op.is_disabled, false) AS owner_is_disabled,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at,
    COUNT(*) OVER() AS total_count
  FROM combined s
  LEFT JOIN public.profiles cp ON cp.id = s.client_id
  LEFT JOIN public.profiles op ON op.id = s.owner_manager_id
  LEFT JOIN public.shop_members sm
    ON sm.root_manager_id = v_root
   AND sm.client_id = s.client_id
  ORDER BY s.relation_created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO service_role;