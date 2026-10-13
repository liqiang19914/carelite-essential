-- ============================================================
-- 公开短链：managers.short_code 字段 + 生成函数 + trigger + 回填
-- + resolve_manager_id RPC + get_public_manager_card 增字段
-- ============================================================

-- 1. 加 short_code 字段（VARCHAR(12)，未来留 vanity slug 余地）
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS short_code VARCHAR(12);

-- 2. CHECK 约束：仅小写字母 + 数字，长度 6-12
ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_short_code_format_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_short_code_format_check
  CHECK (short_code IS NULL OR short_code ~ '^[a-z0-9]{6,12}$');

-- 3. 唯一索引（部分索引避免 NULL 占用空间）
DROP INDEX IF EXISTS managers_short_code_uniq;
CREATE UNIQUE INDEX managers_short_code_uniq
  ON public.managers (short_code)
  WHERE short_code IS NOT NULL;

-- 4. 生成函数：6 位 base36 小写，循环重试
CREATE OR REPLACE FUNCTION public.generate_manager_short_code()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  alphabet TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  result TEXT;
  i INT;
  rand_idx INT;
  attempts INT := 0;
BEGIN
  LOOP
    attempts := attempts + 1;
    IF attempts > 10 THEN
      RAISE EXCEPTION 'manager short_code generation exceeded 10 attempts';
    END IF;
    result := '';
    FOR i IN 1..6 LOOP
      rand_idx := 1 + floor(random() * 36)::int;
      result := result || substr(alphabet, rand_idx, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.managers WHERE short_code = result
    );
  END LOOP;
  RETURN result;
END;
$$;

-- 5. INSERT trigger：自动填充 short_code（若为空）
CREATE OR REPLACE FUNCTION public.managers_set_short_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.short_code IS NULL OR NEW.short_code = '' THEN
    NEW.short_code := public.generate_manager_short_code();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS managers_set_short_code_before_insert ON public.managers;
CREATE TRIGGER managers_set_short_code_before_insert
  BEFORE INSERT ON public.managers
  FOR EACH ROW
  EXECUTE FUNCTION public.managers_set_short_code();

-- 6. 回填现有 managers：逐行调用生成函数（不依赖 trigger，因为 UPDATE 不触发 BEFORE INSERT）
DO $$
DECLARE
  v_id UUID;
  v_code TEXT;
BEGIN
  FOR v_id IN
    SELECT id FROM public.managers WHERE short_code IS NULL
  LOOP
    v_code := public.generate_manager_short_code();
    UPDATE public.managers SET short_code = v_code WHERE id = v_id;
  END LOOP;
END $$;

-- 7. resolve_manager_id RPC：长度 36 → cast UUID 并校验存在；长度 6-12 → 查 short_code
CREATE OR REPLACE FUNCTION public.resolve_manager_id(p_slug_or_id TEXT)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id UUID;
  v_normalized TEXT;
BEGIN
  IF p_slug_or_id IS NULL THEN
    RETURN NULL;
  END IF;
  v_normalized := lower(trim(p_slug_or_id));
  IF length(v_normalized) = 36 THEN
    BEGIN
      v_id := v_normalized::uuid;
    EXCEPTION WHEN OTHERS THEN
      RETURN NULL;
    END;
    IF EXISTS (SELECT 1 FROM public.managers WHERE id = v_id) THEN
      RETURN v_id;
    ELSE
      RETURN NULL;
    END IF;
  ELSIF length(v_normalized) BETWEEN 6 AND 12 THEN
    SELECT id INTO v_id
    FROM public.managers
    WHERE short_code = v_normalized
    LIMIT 1;
    RETURN v_id;
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_manager_id(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_manager_id(TEXT) TO anon, authenticated;

-- 8. get_public_manager_card：返回 JSON 增加 short_code
CREATE OR REPLACE FUNCTION public.get_public_manager_card(p_manager_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_manager managers%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_courses JSON;
  v_featured_products JSON;
  v_is_example BOOLEAN;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = p_manager_id;

  v_is_example := COALESCE(v_manager.is_example, false);

  SELECT json_agg(
    json_build_object(
      'id', c.id,
      'title', c.title,
      'cover_image_url', c.cover_image_url,
      'description', c.description,
      'duration_minutes', c.duration_minutes,
      'chapter_count', (
        SELECT COUNT(*)
        FROM manager_course_chapters mcc
        WHERE mcc.course_id = c.id AND mcc.is_active = true
      ),
      'sort_weight', c.sort_weight,
      'visibility', c.visibility
    )
    ORDER BY c.sort_weight DESC, c.created_at DESC
  ) INTO v_courses
  FROM manager_courses c
  WHERE c.manager_id = p_manager_id
    AND c.is_published = true
    AND c.review_status = 'approved';

  IF v_manager.featured_product_ids IS NOT NULL
     AND array_length(v_manager.featured_product_ids, 1) > 0 THEN
    SELECT json_agg(
      json_build_object(
        'id', p.id,
        'title', p.title,
        'cover_image_url', p.cover_image_url,
        'price_cents', sku.price_cents
      )
    ) INTO v_featured_products
    FROM products p
    LEFT JOIN product_skus sku
      ON sku.product_id = p.id
     AND sku.is_default = true
     AND sku.is_active = true
    WHERE p.id = ANY (v_manager.featured_product_ids)
      AND p.status = 'active';
  END IF;

  RETURN json_build_object(
    'manager_id', v_manager.id,
    'short_code', v_manager.short_code,
    'display_name', COALESCE(v_manager.partner_card_display_name, v_profile.nickname, '健康管理师'),
    'avatar_url', COALESCE(v_manager.digital_avatar_image_url, v_manager.partner_card_avatar_url, v_profile.avatar_url),
    'tagline', v_manager.tagline,
    'company_name', COALESCE(v_manager.company_name, v_manager.partner_card_company_name, v_manager.business_name),
    'intro_personal', v_manager.intro_personal,
    'intro_company', v_manager.intro_company,
    'credentials', v_manager.credentials,
    'digital_persona_video_url', v_manager.digital_persona_video_url,
    'partner_card_public_url', v_manager.partner_card_public_url,
    'partner_card_synced_at', v_manager.partner_card_synced_at,
    'is_example', v_is_example,
    'featured_products', COALESCE(v_featured_products, '[]'::JSON),
    'courses', COALESCE(v_courses, '[]'::JSON)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_public_manager_card(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_manager_card(UUID) TO anon, authenticated;