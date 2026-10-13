-- ============================================================
-- 课程中心 V2 — 数据模型重构 + 审核闭环 + 章节真行 + 进度记忆
-- ============================================================

-- 1. manager_course_chapters：章节独立表（替代 JSONB 兜底）
CREATE TABLE IF NOT EXISTS manager_course_chapters (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id        UUID NOT NULL REFERENCES manager_courses(id) ON DELETE CASCADE,
  sort_order       INTEGER NOT NULL DEFAULT 0,
  title            TEXT NOT NULL,
  intro            TEXT,
  duration_seconds INTEGER,
  video_url        TEXT,
  video_storage_key TEXT,
  video_source     TEXT NOT NULL DEFAULT 'upload'
    CHECK (video_source IN ('upload','external_url','embed')),
  cover_url        TEXT,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  is_free_preview  BOOLEAN NOT NULL DEFAULT false,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mcc_course_sort
  ON manager_course_chapters (course_id, sort_order);

ALTER TABLE manager_course_chapters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "mcc_owner_all" ON manager_course_chapters;
CREATE POLICY "mcc_owner_all"
  ON manager_course_chapters FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM manager_courses c
      WHERE c.id = manager_course_chapters.course_id
        AND (c.manager_id = auth.uid() OR public.is_admin(auth.uid()))
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM manager_courses c
      WHERE c.id = manager_course_chapters.course_id
        AND (c.manager_id = auth.uid() OR public.is_admin(auth.uid()))
    )
  );

DROP TRIGGER IF EXISTS mcc_set_updated_at ON manager_course_chapters;
CREATE TRIGGER mcc_set_updated_at
  BEFORE UPDATE ON manager_course_chapters
  FOR EACH ROW EXECUTE FUNCTION public.shop_set_updated_at();

-- 2. manager_courses：加审核 / 可见性列
ALTER TABLE manager_courses
  ADD COLUMN IF NOT EXISTS review_status TEXT NOT NULL DEFAULT 'draft'
    CHECK (review_status IN ('draft','pending_review','approved','rejected')),
  ADD COLUMN IF NOT EXISTS review_note   TEXT,
  ADD COLUMN IF NOT EXISTS reviewed_by   UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS reviewed_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS submitted_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS visibility    TEXT NOT NULL DEFAULT 'public'
    CHECK (visibility IN ('public','clients_only'));

CREATE INDEX IF NOT EXISTS idx_manager_courses_review
  ON manager_courses (review_status, submitted_at DESC NULLS LAST);

-- 韩老师 example 课程默认 approved（这些是 demo 数据，无需走审核流）
UPDATE manager_courses
   SET review_status = 'approved'
 WHERE manager_id = '00000000-0000-0000-0000-00000000a001'
   AND review_status = 'draft';

-- 3. 把现有 JSONB chapters 行迁到新表（只迁 chapters 是数组且非空的）
INSERT INTO manager_course_chapters
  (course_id, sort_order, title, intro, duration_seconds)
SELECT
  mc.id,
  (ord_idx - 1)::INTEGER,
  COALESCE(NULLIF(ch->>'title', ''), '第 ' || ord_idx || ' 章'),
  ch->>'intro',
  COALESCE(NULLIF((ch->>'duration_minutes'), '')::INTEGER, 0) * 60
FROM manager_courses mc,
     LATERAL jsonb_array_elements(mc.chapters)
       WITH ORDINALITY AS t(ch, ord_idx)
WHERE jsonb_typeof(mc.chapters) = 'array'
  AND jsonb_array_length(mc.chapters) > 0
  AND NOT EXISTS (
    SELECT 1 FROM manager_course_chapters mcc WHERE mcc.course_id = mc.id
  );

-- 4. user_course_chapter_progress：进度记忆
CREATE TABLE IF NOT EXISTS user_course_chapter_progress (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chapter_id       UUID NOT NULL REFERENCES manager_course_chapters(id) ON DELETE CASCADE,
  progress_seconds INTEGER NOT NULL DEFAULT 0,
  is_completed     BOOLEAN NOT NULL DEFAULT false,
  last_played_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, chapter_id)
);

CREATE INDEX IF NOT EXISTS idx_ucp_user
  ON user_course_chapter_progress (user_id, last_played_at DESC);
CREATE INDEX IF NOT EXISTS idx_ucp_chapter
  ON user_course_chapter_progress (chapter_id);

ALTER TABLE user_course_chapter_progress ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ucp_self_rw" ON user_course_chapter_progress;
CREATE POLICY "ucp_self_rw"
  ON user_course_chapter_progress FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "ucp_admin_read" ON user_course_chapter_progress;
CREATE POLICY "ucp_admin_read"
  ON user_course_chapter_progress FOR SELECT
  USING (public.is_admin(auth.uid()));

DROP TRIGGER IF EXISTS ucp_set_updated_at ON user_course_chapter_progress;
CREATE TRIGGER ucp_set_updated_at
  BEFORE UPDATE ON user_course_chapter_progress
  FOR EACH ROW EXECUTE FUNCTION public.shop_set_updated_at();

-- 5. 章节变动 → 父课程自动 revert 到 draft（保护已审核内容不被静悄悄改）
CREATE OR REPLACE FUNCTION public.revert_course_review_on_chapter_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_course_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_course_id := OLD.course_id;
  ELSE
    v_course_id := NEW.course_id;
  END IF;

  UPDATE manager_courses
     SET review_status = 'draft',
         submitted_at  = NULL,
         reviewed_at   = NULL,
         reviewed_by   = NULL,
         review_note   = NULL
   WHERE id = v_course_id
     AND review_status IN ('approved','rejected','pending_review');

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS mcc_revert_course_review ON manager_course_chapters;
CREATE TRIGGER mcc_revert_course_review
  AFTER INSERT OR UPDATE OR DELETE ON manager_course_chapters
  FOR EACH ROW EXECUTE FUNCTION public.revert_course_review_on_chapter_change();

-- ============================================================
-- 6. 改写 get_public_manager_card —— 课程过滤 approved
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

-- ============================================================
-- 7. 改写 get_public_manager_course —— 真章节 + 可见性校验
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_public_manager_course(
  p_manager_id UUID,
  p_course_id  UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_course    manager_courses%ROWTYPE;
  v_chapters  JSON;
  v_is_bound  BOOLEAN := false;
  v_uid       UUID;
BEGIN
  IF p_manager_id IS NULL OR p_course_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_uid := auth.uid();

  SELECT * INTO v_course
  FROM manager_courses
  WHERE id = p_course_id
    AND manager_id = p_manager_id
    AND is_published = true
    AND review_status = 'approved';

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- clients_only 可见性：必须是已绑定的本管理师客户
  IF v_course.visibility = 'clients_only' THEN
    IF v_uid IS NULL THEN
      RETURN json_build_object(
        'gated', true,
        'reason', 'unauthenticated',
        'manager_id', v_course.manager_id
      );
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM client_relations
      WHERE client_id  = v_uid
        AND manager_id = p_manager_id
        AND status     = 'active'
    ) INTO v_is_bound;

    IF NOT v_is_bound AND NOT public.is_admin(v_uid) THEN
      RETURN json_build_object(
        'gated', true,
        'reason', 'not_bound',
        'manager_id', v_course.manager_id
      );
    END IF;
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', mcc.id,
      'sort_order', mcc.sort_order,
      'title', mcc.title,
      'intro', mcc.intro,
      'duration_seconds', mcc.duration_seconds,
      'video_url', mcc.video_url,
      'video_source', mcc.video_source,
      'cover_url', mcc.cover_url,
      'is_free_preview', mcc.is_free_preview,
      'is_active', mcc.is_active
    )
    ORDER BY mcc.sort_order ASC, mcc.created_at ASC
  ) INTO v_chapters
  FROM manager_course_chapters mcc
  WHERE mcc.course_id = v_course.id
    AND mcc.is_active = true;

  RETURN json_build_object(
    'id', v_course.id,
    'manager_id', v_course.manager_id,
    'title', v_course.title,
    'cover_image_url', v_course.cover_image_url,
    'description', v_course.description,
    'duration_minutes', v_course.duration_minutes,
    'visibility', v_course.visibility,
    'chapters', COALESCE(v_chapters, '[]'::JSON),
    'created_at', v_course.created_at
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_public_manager_course(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_manager_course(UUID, UUID) TO anon, authenticated;

-- ============================================================
-- 8. RPC: list_my_course_chapters —— manager 本人或 admin 看自己课程所有章节
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_my_course_chapters(p_course_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid       UUID;
  v_owner_id  UUID;
  v_chapters  JSON;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT manager_id INTO v_owner_id FROM manager_courses WHERE id = p_course_id;
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  IF v_owner_id <> v_uid AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '无权访问' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', mcc.id,
      'sort_order', mcc.sort_order,
      'title', mcc.title,
      'intro', mcc.intro,
      'duration_seconds', mcc.duration_seconds,
      'video_url', mcc.video_url,
      'video_storage_key', mcc.video_storage_key,
      'video_source', mcc.video_source,
      'cover_url', mcc.cover_url,
      'is_free_preview', mcc.is_free_preview,
      'is_active', mcc.is_active,
      'created_at', mcc.created_at,
      'updated_at', mcc.updated_at
    )
    ORDER BY mcc.sort_order ASC, mcc.created_at ASC
  ) INTO v_chapters
  FROM manager_course_chapters mcc
  WHERE mcc.course_id = p_course_id;

  RETURN COALESCE(v_chapters, '[]'::JSON);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_my_course_chapters(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_course_chapters(UUID) TO authenticated;

-- ============================================================
-- 9. RPC: submit_course_for_review —— 提交审核
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_course_for_review(p_course_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       UUID;
  v_course    manager_courses%ROWTYPE;
  v_chap_cnt  INTEGER;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_course FROM manager_courses WHERE id = p_course_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  IF v_course.manager_id <> v_uid THEN
    RAISE EXCEPTION '只能提交自己的课程' USING ERRCODE = '42501';
  END IF;

  IF v_course.review_status = 'pending_review' THEN
    RAISE EXCEPTION '已在审核队列中' USING ERRCODE = '22023';
  END IF;

  IF v_course.review_status = 'approved' THEN
    RAISE EXCEPTION '课程已通过审核，无需重复提交' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*) INTO v_chap_cnt
    FROM manager_course_chapters mcc
   WHERE mcc.course_id = p_course_id AND mcc.is_active = true;

  IF v_chap_cnt = 0 THEN
    RAISE EXCEPTION '请至少添加一个有效章节后再提交' USING ERRCODE = '22023';
  END IF;

  UPDATE manager_courses
     SET review_status = 'pending_review',
         submitted_at  = NOW(),
         review_note   = NULL
   WHERE id = p_course_id;

  RETURN json_build_object(
    'success', true,
    'course_id', p_course_id,
    'review_status', 'pending_review',
    'submitted_at', NOW()
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.submit_course_for_review(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_course_for_review(UUID) TO authenticated;

-- ============================================================
-- 10. RPC: admin_review_course —— 管理员审核
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_review_course(
  p_course_id UUID,
  p_action    TEXT,
  p_note      TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       UUID;
  v_new_state TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅管理员可审核' USING ERRCODE = '42501';
  END IF;

  IF p_action NOT IN ('approve','reject') THEN
    RAISE EXCEPTION '审核动作非法' USING ERRCODE = '22023';
  END IF;

  IF p_action = 'reject' AND (p_note IS NULL OR length(trim(p_note)) = 0) THEN
    RAISE EXCEPTION '驳回必须填写理由' USING ERRCODE = '22023';
  END IF;

  v_new_state := CASE WHEN p_action = 'approve' THEN 'approved' ELSE 'rejected' END;

  UPDATE manager_courses
     SET review_status = v_new_state,
         review_note   = p_note,
         reviewed_by   = v_uid,
         reviewed_at   = NOW()
   WHERE id = p_course_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  RETURN json_build_object(
    'success', true,
    'course_id', p_course_id,
    'review_status', v_new_state,
    'reviewed_at', NOW()
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_review_course(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_review_course(UUID, TEXT, TEXT) TO authenticated;

-- ============================================================
-- 11. RPC: list_pending_courses_for_admin —— 管理员分页查
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_pending_courses_for_admin(
  p_status TEXT DEFAULT NULL,
  p_limit  INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid     UUID;
  v_total   INTEGER;
  v_items   JSON;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅管理员可访问' USING ERRCODE = '42501';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 20; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN p_offset := 0; END IF;

  SELECT COUNT(*) INTO v_total
  FROM manager_courses c
  WHERE (p_status IS NULL OR c.review_status = p_status);

  SELECT json_agg(item ORDER BY ord) INTO v_items
  FROM (
    SELECT json_build_object(
      'id', c.id,
      'title', c.title,
      'cover_image_url', c.cover_image_url,
      'description', c.description,
      'review_status', c.review_status,
      'review_note', c.review_note,
      'submitted_at', c.submitted_at,
      'reviewed_at', c.reviewed_at,
      'visibility', c.visibility,
      'is_published', c.is_published,
      'chapter_count', (
        SELECT COUNT(*) FROM manager_course_chapters mcc
        WHERE mcc.course_id = c.id AND mcc.is_active = true
      ),
      'duration_minutes', c.duration_minutes,
      'manager_id', c.manager_id,
      'manager_name', COALESCE(m.partner_card_display_name, p.nickname, '健康管理师'),
      'manager_avatar', COALESCE(m.digital_avatar_image_url, m.partner_card_avatar_url, p.avatar_url),
      'created_at', c.created_at,
      'updated_at', c.updated_at
    ) AS item,
    ROW_NUMBER() OVER (
      ORDER BY
        CASE WHEN c.review_status = 'pending_review' THEN 0
             WHEN c.review_status = 'rejected'       THEN 1
             ELSE 2 END,
        COALESCE(c.submitted_at, c.updated_at) DESC
    ) AS ord
    FROM manager_courses c
    LEFT JOIN managers m ON m.id = c.manager_id
    LEFT JOIN profiles p ON p.id = c.manager_id
    WHERE (p_status IS NULL OR c.review_status = p_status)
    ORDER BY ord
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN json_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'items', COALESCE(v_items, '[]'::JSON)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_pending_courses_for_admin(TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pending_courses_for_admin(TEXT, INTEGER, INTEGER) TO authenticated;

-- ============================================================
-- 12. RPC: update_chapter_progress —— 写自己看视频的进度
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_chapter_progress(
  p_chapter_id UUID,
  p_seconds    INTEGER,
  p_completed  BOOLEAN DEFAULT false
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_chapter manager_course_chapters%ROWTYPE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_chapter FROM manager_course_chapters WHERE id = p_chapter_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '章节不存在' USING ERRCODE = 'P0002';
  END IF;

  IF p_seconds IS NULL OR p_seconds < 0 THEN p_seconds := 0; END IF;

  INSERT INTO user_course_chapter_progress
    (user_id, chapter_id, progress_seconds, is_completed, last_played_at)
  VALUES
    (v_uid, p_chapter_id, p_seconds, COALESCE(p_completed, false), NOW())
  ON CONFLICT (user_id, chapter_id)
  DO UPDATE SET
    progress_seconds = GREATEST(user_course_chapter_progress.progress_seconds, EXCLUDED.progress_seconds),
    is_completed     = user_course_chapter_progress.is_completed OR EXCLUDED.is_completed,
    last_played_at   = NOW();

  RETURN json_build_object(
    'success', true,
    'chapter_id', p_chapter_id,
    'progress_seconds', p_seconds,
    'is_completed', COALESCE(p_completed, false)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_chapter_progress(UUID, INTEGER, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_chapter_progress(UUID, INTEGER, BOOLEAN) TO authenticated;

-- ============================================================
-- 13. RPC: get_chapter_progress_batch —— 一次拉一组章节的进度
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_chapter_progress_batch(p_chapter_ids UUID[])
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid UUID;
  v_items JSON;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN '[]'::JSON;
  END IF;

  SELECT json_agg(
    json_build_object(
      'chapter_id', ucp.chapter_id,
      'progress_seconds', ucp.progress_seconds,
      'is_completed', ucp.is_completed,
      'last_played_at', ucp.last_played_at
    )
  ) INTO v_items
  FROM user_course_chapter_progress ucp
  WHERE ucp.user_id = v_uid
    AND ucp.chapter_id = ANY (p_chapter_ids);

  RETURN COALESCE(v_items, '[]'::JSON);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_chapter_progress_batch(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_chapter_progress_batch(UUID[]) TO authenticated;