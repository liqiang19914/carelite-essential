-- 内容机检放宽 + 后台人工放行闭环
-- 1) 机检"没看完"不再等于"拦下来"：新增覆盖度字段，如实记录而不阻断上线
-- 2) 机检"彻底失败"不再停在 pending 永久卡死：改为进人工队列
-- 3) 新增 approve（放行上线）动作，覆盖 flagged / manual_review / pending 三种未上线状态
-- 4) approve 与 restore 都绝不触碰 is_published —— 放行只解除审核结论，不替商户决定是否上架

-- ===== 一、新增字段 =====
ALTER TABLE public.manager_content_items
  ADD COLUMN IF NOT EXISTS moderation_incomplete boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_approved_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_approved_at timestamptz;

COMMENT ON COLUMN public.manager_content_items.moderation_incomplete IS
  '机检未覆盖全部素材（图片超量 / 长文采样 / 部分批次失败）。仅用于如实披露覆盖度，不阻断上线。';
COMMENT ON COLUMN public.manager_content_items.last_approved_by IS
  '最近一次人工放行的管理员。仅审计用，不构成对后续编辑版本的免检授权。';
COMMENT ON COLUMN public.manager_content_items.last_approved_at IS
  '最近一次人工放行时间。仅审计用。';

-- 新字段不进 authenticated 的列级 UPDATE 白名单，商户端无法自行改写覆盖度与放行审计

-- ===== 二、机检结果写回：放宽状态映射 =====
DROP FUNCTION IF EXISTS public.apply_content_moderation_result(
  uuid, timestamptz, text, jsonb, text, integer, integer, text
);

CREATE FUNCTION public.apply_content_moderation_result(
  p_content_id uuid,
  p_expected_updated_at timestamptz,
  p_verdict text,
  p_labels jsonb,
  p_summary text,
  p_checked_images integer,
  p_total_images integer,
  p_error text DEFAULT NULL,
  p_incomplete boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_item public.manager_content_items%ROWTYPE;
  v_status text;
  v_incomplete boolean;
BEGIN
  IF p_verdict NOT IN ('pass', 'reject', 'partial', 'error') THEN
    RAISE EXCEPTION 'invalid verdict' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'not_found');
  END IF;

  IF v_item.updated_at IS DISTINCT FROM p_expected_updated_at THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'stale');
  END IF;

  -- 已被平台人工下架的内容，机检结论一律不得改变其状态
  IF v_item.moderation_status = 'blocked' THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'blocked');
  END IF;

  v_incomplete := COALESCE(p_incomplete, false) OR p_verdict = 'partial';

  v_status := CASE
    -- 一条有效结论都没拿到（网关全挂 / 全部无法解析）：进人工队列等人看，
    -- 绝不再停在 pending —— 没有任何机制会自动重试 pending，那等于永久消失。
    WHEN p_verdict = 'error' THEN 'manual_review'
    -- 命中硬红线
    WHEN p_verdict = 'reject' THEN 'flagged'
    -- 被平台下架过的内容：安全钉子优先，机检通过也只能停在人工复核
    WHEN v_item.requires_manual_review THEN 'manual_review'
    -- pass 与 partial 一律放行。机器没看完不是违规证据，只如实记覆盖度。
    ELSE 'passed'
  END;

  UPDATE public.manager_content_items
     SET moderation_status = v_status,
         moderation_labels = COALESCE(p_labels, '[]'::jsonb),
         moderation_summary = NULLIF(btrim(COALESCE(p_summary, '')), ''),
         moderation_checked_images = GREATEST(COALESCE(p_checked_images, 0), 0),
         moderation_total_images = GREATEST(COALESCE(p_total_images, 0), 0),
         moderation_error = NULLIF(btrim(COALESCE(p_error, '')), ''),
         moderation_incomplete = v_incomplete,
         moderation_attempts = v_item.moderation_attempts + 1,
         moderated_at = now()
   WHERE id = p_content_id;

  RETURN jsonb_build_object(
    'applied', true,
    'content_id', p_content_id,
    'moderation_status', v_status,
    'moderation_incomplete', v_incomplete
  );
END;
$$;

REVOKE ALL ON FUNCTION public.apply_content_moderation_result(
  uuid, timestamptz, text, jsonb, text, integer, integer, text, boolean
) FROM PUBLIC, anon, authenticated;

-- ===== 三、商户发布：一并重置覆盖度 =====
CREATE OR REPLACE FUNCTION public.publish_content(p_content_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.manager_content_items%ROWTYPE;
  v_page_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再发布' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '内容不存在，请返回列表后刷新' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(v_uid)
     AND (
       NOT public.is_active_enterprise_content_member(v_uid)
       OR v_item.root_manager_id IS DISTINCT FROM
          public.get_enterprise_root_manager_id(v_uid)
     ) THEN
    RAISE EXCEPTION '只能发布本企业的内容' USING ERRCODE = '42501';
  END IF;

  IF NULLIF(btrim(v_item.title), '') IS NULL THEN
    RAISE EXCEPTION '请先填写标题再发布' USING ERRCODE = '22023';
  END IF;

  IF NULLIF(btrim(v_item.cover_url), '') IS NULL THEN
    RAISE EXCEPTION '请先上传封面图再发布' USING ERRCODE = '22023';
  END IF;

  IF v_item.content_type = 'article'
     AND NOT public.manager_content_document_has_body(v_item.article_doc) THEN
    RAISE EXCEPTION '正文还是空的，请先写点内容再发布' USING ERRCODE = '22023';
  END IF;

  IF v_item.content_type = 'album' THEN
    SELECT COUNT(*) INTO v_page_count
    FROM public.manager_content_album_pages
    WHERE content_id = p_content_id;

    IF v_page_count = 0 THEN
      RAISE EXCEPTION '画册里还没有图片，请先上传至少一张再发布' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 已被平台下架的内容仍允许重新发布，但机检通过后只会停在待人工复核
  UPDATE public.manager_content_items
     SET is_published = true,
         moderation_status = 'pending',
         moderation_labels = '[]'::jsonb,
         moderation_summary = NULL,
         moderation_checked_images = 0,
         moderation_total_images = 0,
         moderation_error = NULL,
         moderation_incomplete = false,
         moderation_attempts = 0,
         moderated_at = NULL
   WHERE id = p_content_id;

  RETURN jsonb_build_object(
    'success', true,
    'content_id', p_content_id,
    'moderation_status', 'pending',
    'requires_manual_review', v_item.requires_manual_review
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_content(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publish_content(uuid) TO authenticated;

-- ===== 四、平台处置：新增 approve、加状态前置校验与版本校验 =====
DROP FUNCTION IF EXISTS public.admin_content_action(uuid, text, text);

CREATE FUNCTION public.admin_content_action(
  p_content_id uuid,
  p_action text,
  p_note text DEFAULT NULL,
  p_expected_updated_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.manager_content_items%ROWTYPE;
  v_note text := NULLIF(btrim(p_note), '');
  v_status text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可处置内容' USING ERRCODE = '42501';
  END IF;

  IF p_action NOT IN ('takedown', 'restore', 'approve', 'recheck') THEN
    RAISE EXCEPTION '请选择「下架」「解除下架」「放行上线」或「重新检测」' USING ERRCODE = '22023';
  END IF;

  IF p_action = 'takedown' AND v_note IS NULL THEN
    RAISE EXCEPTION '下架必须填写原因，商户需要知道该改什么' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '内容不存在或已被删除' USING ERRCODE = 'P0002';
  END IF;

  -- 版本校验只挂在"会让内容变可见"的两个动作上。
  -- takedown / recheck 属于收紧方向，任何时候都必须能立即执行，绝不因为版本对不上而被挡住。
  IF p_action IN ('approve', 'restore')
     AND p_expected_updated_at IS NOT NULL
     AND v_item.updated_at IS DISTINCT FROM p_expected_updated_at THEN
    RAISE EXCEPTION '这条内容刚刚有了新的改动或新的检测结果，请刷新后重新确认再放行'
      USING ERRCODE = '40001';
  END IF;

  IF p_action = 'takedown' THEN
    UPDATE public.manager_content_items
       SET moderation_status = 'blocked',
           requires_manual_review = true,
           takedown_note = v_note,
           taken_down_by = v_uid,
           taken_down_at = now(),
           moderated_at = now()
     WHERE id = p_content_id;
    v_status := 'blocked';

  ELSIF p_action = 'restore' THEN
    IF v_item.moderation_status <> 'blocked' THEN
      RAISE EXCEPTION '这条内容当前不是平台下架状态，无需解除下架' USING ERRCODE = '22023';
    END IF;
    -- 不动 is_published：解除下架只撤销平台处置，是否上架仍由商户自己决定
    UPDATE public.manager_content_items
       SET moderation_status = 'passed',
           takedown_note = NULL,
           last_approved_by = v_uid,
           last_approved_at = now(),
           moderated_at = now()
     WHERE id = p_content_id;
    v_status := 'passed';

  ELSIF p_action = 'approve' THEN
    IF v_item.moderation_status NOT IN ('flagged', 'manual_review', 'pending') THEN
      RAISE EXCEPTION '这条内容当前不在待处理状态，无需放行' USING ERRCODE = '22023';
    END IF;
    -- 同样不动 is_published，也不清 requires_manual_review：
    -- 这次放行只对当前这一版负责，商户之后再改内容仍要重新走检测。
    UPDATE public.manager_content_items
       SET moderation_status = 'passed',
           moderation_error = NULL,
           last_approved_by = v_uid,
           last_approved_at = now(),
           moderated_at = now()
     WHERE id = p_content_id;
    v_status := 'passed';

  ELSE
    UPDATE public.manager_content_items
       SET moderation_status = 'pending',
           moderation_labels = '[]'::jsonb,
           moderation_summary = NULL,
           moderation_checked_images = 0,
           moderation_total_images = 0,
           moderation_error = NULL,
           moderation_incomplete = false,
           moderation_attempts = 0,
           moderated_at = NULL
     WHERE id = p_content_id;
    v_status := 'pending';
  END IF;

  SELECT * INTO v_item
  FROM public.manager_content_items
  WHERE id = p_content_id;

  RETURN jsonb_build_object(
    'success', true,
    'content_id', p_content_id,
    'moderation_status', v_status,
    'is_published', v_item.is_published,
    'updated_at', v_item.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_content_action(uuid, text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_content_action(uuid, text, text, timestamptz) TO authenticated;

-- ===== 五、两个重置触发器：同步清空覆盖度标记（保留 service_role 旁路）=====
CREATE OR REPLACE FUNCTION public.manager_content_items_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean := COALESCE(public.is_admin(v_uid), false);
  v_is_service boolean := COALESCE(
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  ) = 'service_role';
  v_material_changed boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT v_is_admin AND NOT v_is_service THEN
      IF NOT public.is_active_enterprise_content_member(v_uid) THEN
        RAISE EXCEPTION '所属企业当前不可使用内容管理，请联系企业负责人或平台处理'
          USING ERRCODE = '42501';
      END IF;
      NEW.root_manager_id := public.get_enterprise_root_manager_id(v_uid);
    ELSIF NEW.root_manager_id IS NULL THEN
      RAISE EXCEPTION '请选择内容所属企业' USING ERRCODE = '22023';
    END IF;

    NEW.is_published := false;
    NEW.moderation_status := 'pending';
    NEW.moderation_labels := '[]'::jsonb;
    NEW.moderation_summary := NULL;
    NEW.moderation_checked_images := 0;
    NEW.moderation_total_images := 0;
    NEW.moderation_error := NULL;
    NEW.moderation_incomplete := false;
    NEW.moderation_attempts := 0;
    NEW.moderated_at := NULL;
    NEW.requires_manual_review := false;
    NEW.takedown_note := NULL;
    NEW.taken_down_by := NULL;
    NEW.taken_down_at := NULL;
    NEW.last_approved_by := NULL;
    NEW.last_approved_at := NULL;
    NEW.created_by := v_uid;
    NEW.updated_by := v_uid;
    NEW.created_at := now();
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF NOT v_is_admin AND NOT v_is_service THEN
    IF NOT public.is_active_enterprise_content_member(v_uid)
       OR OLD.root_manager_id IS DISTINCT FROM
          public.get_enterprise_root_manager_id(v_uid) THEN
      RAISE EXCEPTION '你已无权修改该企业内容，请刷新页面或联系企业负责人'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  NEW.root_manager_id := OLD.root_manager_id;
  NEW.content_type := OLD.content_type;
  NEW.created_by := OLD.created_by;
  NEW.created_at := OLD.created_at;

  v_material_changed :=
       NEW.title IS DISTINCT FROM OLD.title
    OR NEW.cover_url IS DISTINCT FROM OLD.cover_url
    OR NEW.cover_storage_key IS DISTINCT FROM OLD.cover_storage_key
    OR NEW.article_doc IS DISTINCT FROM OLD.article_doc;

  IF v_material_changed THEN
    NEW.moderation_status := 'pending';
    NEW.moderation_labels := '[]'::jsonb;
    NEW.moderation_summary := NULL;
    NEW.moderation_checked_images := 0;
    NEW.moderation_total_images := 0;
    NEW.moderation_error := NULL;
    NEW.moderation_incomplete := false;
    NEW.moderation_attempts := 0;
    NEW.moderated_at := NULL;
  END IF;

  NEW.updated_by := COALESCE(v_uid, OLD.updated_by);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.reset_content_moderation_on_album_page_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_content_id uuid;
BEGIN
  -- 只动了时间戳 / 审计列的更新不算内容变化，避免无意义地把已上线内容打回重检
  IF TG_OP = 'UPDATE'
     AND NEW.sort_order IS NOT DISTINCT FROM OLD.sort_order
     AND NEW.image_url IS NOT DISTINCT FROM OLD.image_url
     AND NEW.image_storage_key IS NOT DISTINCT FROM OLD.image_storage_key
     AND NEW.alt_text IS NOT DISTINCT FROM OLD.alt_text THEN
    RETURN NEW;
  END IF;

  v_content_id := CASE
    WHEN TG_OP = 'DELETE' THEN OLD.content_id
    ELSE NEW.content_id
  END;

  UPDATE public.manager_content_items
     SET moderation_status = 'pending',
         moderation_labels = '[]'::jsonb,
         moderation_summary = NULL,
         moderation_checked_images = 0,
         moderation_total_images = 0,
         moderation_error = NULL,
         moderation_incomplete = false,
         moderation_attempts = 0,
         moderated_at = NULL
   WHERE id = v_content_id
     AND moderation_status <> 'pending';

  RETURN COALESCE(NEW, OLD);
END;
$$;
