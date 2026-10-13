-- ============================================================
-- 健康管理师板块 V1：managers 扩展 + 课程表 + 知识库表 + 6 RPC + RLS 收口
-- ============================================================

-- 1. managers 表扩展（公开名片 / partner-api 缓存 / 主推商品）
ALTER TABLE managers
  ADD COLUMN IF NOT EXISTS intro_personal TEXT,
  ADD COLUMN IF NOT EXISTS intro_company TEXT,
  ADD COLUMN IF NOT EXISTS company_name TEXT,
  ADD COLUMN IF NOT EXISTS digital_avatar_image_url TEXT,
  ADD COLUMN IF NOT EXISTS digital_persona_video_url TEXT,
  ADD COLUMN IF NOT EXISTS tagline TEXT,
  ADD COLUMN IF NOT EXISTS credentials TEXT[],
  ADD COLUMN IF NOT EXISTS partner_phone TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_status TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_public_url TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_slug TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_display_name TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_avatar_url TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_company_name TEXT,
  ADD COLUMN IF NOT EXISTS partner_card_updated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS partner_card_synced_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS partner_card_error TEXT,
  ADD COLUMN IF NOT EXISTS featured_product_ids UUID[] NOT NULL DEFAULT '{}'::UUID[];

-- 2. manager_courses 表（管理师课程目录，本期占位）
CREATE TABLE IF NOT EXISTS manager_courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID NOT NULL REFERENCES managers(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  cover_image_url TEXT,
  description TEXT,
  duration_minutes INTEGER,
  chapters JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_published BOOLEAN NOT NULL DEFAULT false,
  sort_weight INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_manager_courses_manager ON manager_courses (manager_id);
CREATE INDEX IF NOT EXISTS idx_manager_courses_published
  ON manager_courses (manager_id, is_published, sort_weight DESC, created_at DESC);

ALTER TABLE manager_courses ENABLE ROW LEVEL SECURITY;

-- 3. manager_knowledge_documents 表（每管理师专属知识库文档）
CREATE TABLE IF NOT EXISTS manager_knowledge_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID NOT NULL REFERENCES managers(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  storage_url TEXT,
  storage_key TEXT,
  file_size_bytes INTEGER,
  mime_type TEXT,
  backend TEXT NOT NULL CHECK (backend IN ('kqa','bailian')),
  external_file_id TEXT,
  external_index_id TEXT,
  status TEXT NOT NULL DEFAULT 'uploading'
    CHECK (status IN ('uploading','indexing','ready','failed')),
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_manager_knowledge_documents_manager
  ON manager_knowledge_documents (manager_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_manager_knowledge_documents_status
  ON manager_knowledge_documents (manager_id, status);

ALTER TABLE manager_knowledge_documents ENABLE ROW LEVEL SECURITY;

-- updated_at 触发器复用 shop_set_updated_at（已存在），直接挂上去
DROP TRIGGER IF EXISTS manager_courses_set_updated_at ON manager_courses;
CREATE TRIGGER manager_courses_set_updated_at
  BEFORE UPDATE ON manager_courses
  FOR EACH ROW EXECUTE FUNCTION public.shop_set_updated_at();

DROP TRIGGER IF EXISTS manager_knowledge_documents_set_updated_at ON manager_knowledge_documents;
CREATE TRIGGER manager_knowledge_documents_set_updated_at
  BEFORE UPDATE ON manager_knowledge_documents
  FOR EACH ROW EXECUTE FUNCTION public.shop_set_updated_at();

-- 4. 收口 managers SELECT 策略
DROP POLICY IF EXISTS "Authenticated users can find managers by invite code" ON managers;

-- 现有 managers_select_policy 已是 self + is_admin（无变化）
-- 其余访问全部通过 SECURITY DEFINER RPC（白名单字段）

-- 5. manager_courses RLS（owner + admin 可读写；C 端 SELECT 走 RPC）
DROP POLICY IF EXISTS "manager_courses_owner_all" ON manager_courses;
CREATE POLICY "manager_courses_owner_all"
  ON manager_courses FOR ALL
  USING (manager_id = auth.uid() OR public.is_admin(auth.uid()))
  WITH CHECK (manager_id = auth.uid() OR public.is_admin(auth.uid()));

-- 6. manager_knowledge_documents RLS（owner + admin 可读写；C 端无直接访问，service role 通过 EF 操作）
DROP POLICY IF EXISTS "manager_knowledge_documents_owner_all" ON manager_knowledge_documents;
CREATE POLICY "manager_knowledge_documents_owner_all"
  ON manager_knowledge_documents FOR ALL
  USING (manager_id = auth.uid() OR public.is_admin(auth.uid()))
  WITH CHECK (manager_id = auth.uid() OR public.is_admin(auth.uid()));

-- ============================================================
-- 7. SECURITY DEFINER RPC：get_public_manager_card
-- ============================================================
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
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = p_manager_id;

  SELECT json_agg(
    json_build_object(
      'id', c.id,
      'title', c.title,
      'cover_image_url', c.cover_image_url,
      'description', c.description,
      'duration_minutes', c.duration_minutes,
      'chapter_count', COALESCE(jsonb_array_length(c.chapters), 0),
      'sort_weight', c.sort_weight
    )
    ORDER BY c.sort_weight DESC, c.created_at DESC
  ) INTO v_courses
  FROM manager_courses c
  WHERE c.manager_id = p_manager_id AND c.is_published = true;

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
    'featured_products', COALESCE(v_featured_products, '[]'::JSON),
    'courses', COALESCE(v_courses, '[]'::JSON)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_public_manager_card(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_manager_card(UUID) TO anon, authenticated;

-- ============================================================
-- 8. SECURITY DEFINER RPC：get_public_manager_course
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_public_manager_course(
  p_manager_id UUID,
  p_course_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_course manager_courses%ROWTYPE;
BEGIN
  IF p_manager_id IS NULL OR p_course_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_course
  FROM manager_courses
  WHERE id = p_course_id
    AND manager_id = p_manager_id
    AND is_published = true;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'id', v_course.id,
    'manager_id', v_course.manager_id,
    'title', v_course.title,
    'cover_image_url', v_course.cover_image_url,
    'description', v_course.description,
    'duration_minutes', v_course.duration_minutes,
    'chapters', v_course.chapters,
    'created_at', v_course.created_at
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_public_manager_course(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_manager_course(UUID, UUID) TO anon, authenticated;

-- ============================================================
-- 9. SECURITY DEFINER RPC：get_my_bound_manager_card
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_bound_manager_card()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid UUID;
  v_manager_id UUID;
  v_card JSON;
  v_doc_total INTEGER;
  v_doc_ready INTEGER;
  v_doc_failed INTEGER;
  v_doc_indexing INTEGER;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT manager_id INTO v_manager_id
  FROM client_relations
  WHERE client_id = v_uid AND status = 'active'
  ORDER BY updated_at DESC NULLS LAST
  LIMIT 1;

  IF v_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT public.get_public_manager_card(v_manager_id) INTO v_card;

  SELECT
    COUNT(*) FILTER (WHERE TRUE),
    COUNT(*) FILTER (WHERE status = 'ready'),
    COUNT(*) FILTER (WHERE status = 'failed'),
    COUNT(*) FILTER (WHERE status IN ('uploading','indexing'))
  INTO v_doc_total, v_doc_ready, v_doc_failed, v_doc_indexing
  FROM manager_knowledge_documents
  WHERE manager_id = v_manager_id;

  RETURN json_build_object(
    'card', v_card,
    'knowledge', json_build_object(
      'total_documents', v_doc_total,
      'ready_documents', v_doc_ready,
      'failed_documents', v_doc_failed,
      'indexing_documents', v_doc_indexing,
      'has_knowledge', v_doc_ready > 0
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_my_bound_manager_card() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_bound_manager_card() TO authenticated;

-- ============================================================
-- 10. SECURITY DEFINER RPC：bind_manager_from_card（来自公开名片 +invite_code）
-- ============================================================
CREATE OR REPLACE FUNCTION public.bind_manager_from_card(
  p_manager_id UUID,
  p_invite_code TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_existing_id UUID;
  v_relation_id UUID;
  v_normalized TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);
  IF v_manager.invite_code IS NULL OR v_manager.invite_code <> v_normalized THEN
    RAISE EXCEPTION '邀请码错误' USING ERRCODE = '22023';
  END IF;

  -- 解绑旧绑定（不同 manager 时）
  SELECT manager_id INTO v_existing_id
  FROM client_relations
  WHERE client_id = v_uid AND status = 'active' AND manager_id <> p_manager_id
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    UPDATE client_relations
       SET status = 'inactive', updated_at = NOW()
     WHERE client_id = v_uid AND manager_id = v_existing_id;
  END IF;

  -- upsert 当前绑定
  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    INSERT INTO client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (p_manager_id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'manager_id', p_manager_id,
    'relation_id', v_relation_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_from_card(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_card(UUID, TEXT) TO authenticated;

-- ============================================================
-- 11. SECURITY DEFINER RPC：bind_manager_by_invite_code（用 invite_code 反查 manager）
-- ============================================================
CREATE OR REPLACE FUNCTION public.bind_manager_by_invite_code(
  p_invite_code TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_existing_id UUID;
  v_relation_id UUID;
  v_normalized TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);

  SELECT * INTO v_manager FROM managers WHERE invite_code = v_normalized LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION '邀请码无效' USING ERRCODE = 'P0002';
  END IF;

  SELECT manager_id INTO v_existing_id
  FROM client_relations
  WHERE client_id = v_uid AND status = 'active' AND manager_id <> v_manager.id
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    UPDATE client_relations
       SET status = 'inactive', updated_at = NOW()
     WHERE client_id = v_uid AND manager_id = v_existing_id;
  END IF;

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = v_manager.id;

  IF v_relation_id IS NULL THEN
    INSERT INTO client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (v_manager.id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'manager_id', v_manager.id,
    'relation_id', v_relation_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_by_invite_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_by_invite_code(TEXT) TO authenticated;

-- ============================================================
-- 12. SECURITY DEFINER RPC：unbind_my_manager
-- ============================================================
CREATE OR REPLACE FUNCTION public.unbind_my_manager()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_count INTEGER;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  UPDATE client_relations
     SET status = 'inactive', updated_at = NOW()
   WHERE client_id = v_uid AND status = 'active';
  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN json_build_object('success', true, 'unbound_count', v_count);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.unbind_my_manager() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unbind_my_manager() TO authenticated;