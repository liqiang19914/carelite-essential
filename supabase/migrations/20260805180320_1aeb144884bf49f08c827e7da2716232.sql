-- 商户内容中心：发布 / 商户下架 / 申请人工复核 / 平台处置 / 机检结果写回

-- 1. 商户发布：完整性校验通过后进入待检测；由前端接着调用检测服务
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

-- 2. 商户自己下架：只改上架开关，不动机检结论
CREATE OR REPLACE FUNCTION public.unpublish_content(p_content_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再操作' USING ERRCODE = '28000';
  END IF;

  SELECT root_manager_id INTO v_root
  FROM public.manager_content_items
  WHERE id = p_content_id
  FOR UPDATE;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '内容不存在，请返回列表后刷新' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(v_uid)
     AND (
       NOT public.is_active_enterprise_content_member(v_uid)
       OR v_root IS DISTINCT FROM public.get_enterprise_root_manager_id(v_uid)
     ) THEN
    RAISE EXCEPTION '只能操作本企业的内容' USING ERRCODE = '42501';
  END IF;

  UPDATE public.manager_content_items
     SET is_published = false
   WHERE id = p_content_id;

  RETURN jsonb_build_object('success', true, 'content_id', p_content_id);
END;
$$;

REVOKE ALL ON FUNCTION public.unpublish_content(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unpublish_content(uuid) TO authenticated;

-- 3. 商户申请人工复核：机检误判时的解锁通道，否则一次误判就是死结
CREATE OR REPLACE FUNCTION public.request_manual_review(p_content_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.manager_content_items%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再操作' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '内容不存在，请返回列表后刷新' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_active_enterprise_content_member(v_uid)
     OR v_item.root_manager_id IS DISTINCT FROM
        public.get_enterprise_root_manager_id(v_uid) THEN
    RAISE EXCEPTION '只能为本企业的内容申请复核' USING ERRCODE = '42501';
  END IF;

  IF v_item.moderation_status = 'blocked' THEN
    RAISE EXCEPTION '这条内容已被平台下架，请先按下架原因修改，再重新发布'
      USING ERRCODE = '22023';
  END IF;

  IF v_item.moderation_status NOT IN ('flagged', 'pending') THEN
    RAISE EXCEPTION '当前状态不需要申请人工复核' USING ERRCODE = '22023';
  END IF;

  UPDATE public.manager_content_items
     SET moderation_status = 'manual_review',
         is_published = true,
         moderated_at = now()
   WHERE id = p_content_id;

  RETURN jsonb_build_object(
    'success', true,
    'content_id', p_content_id,
    'moderation_status', 'manual_review'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.request_manual_review(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_manual_review(uuid) TO authenticated;

-- 4. 平台处置：下架 / 恢复上线 / 重新检测
--    下架把 requires_manual_review 永久置 true —— 这是安全钉子，商户此后改一个字
--    也无法靠机检自动重新上线，必须人工再放行。
CREATE OR REPLACE FUNCTION public.admin_content_action(
  p_content_id uuid,
  p_action text,
  p_note text DEFAULT NULL
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

  IF p_action NOT IN ('takedown', 'restore', 'recheck') THEN
    RAISE EXCEPTION '请选择「下架」「恢复上线」或「重新检测」' USING ERRCODE = '22023';
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
    UPDATE public.manager_content_items
       SET moderation_status = 'passed',
           takedown_note = NULL,
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
           moderation_attempts = 0,
           moderated_at = NULL
     WHERE id = p_content_id;
    v_status := 'pending';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'content_id', p_content_id,
    'moderation_status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_content_action(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_content_action(uuid, text, text) TO authenticated;

-- 5. 机检结果写回：只给 service_role（检测服务）用。
--    p_expected_updated_at 保证检测期间内容没被改过；改过就丢弃这次结论、保持待检测，
--    绝不用旧内容的结论给新内容放行。
CREATE OR REPLACE FUNCTION public.apply_content_moderation_result(
  p_content_id uuid,
  p_expected_updated_at timestamptz,
  p_verdict text,
  p_labels jsonb,
  p_summary text,
  p_checked_images integer,
  p_total_images integer,
  p_error text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_item public.manager_content_items%ROWTYPE;
  v_status text;
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

  v_status := CASE
    WHEN p_verdict = 'error' THEN 'pending'
    WHEN p_verdict = 'reject' THEN 'flagged'
    WHEN p_verdict = 'partial' THEN 'manual_review'
    WHEN v_item.requires_manual_review THEN 'manual_review'
    ELSE 'passed'
  END;

  UPDATE public.manager_content_items
     SET moderation_status = v_status,
         moderation_labels = COALESCE(p_labels, '[]'::jsonb),
         moderation_summary = NULLIF(btrim(COALESCE(p_summary, '')), ''),
         moderation_checked_images = GREATEST(COALESCE(p_checked_images, 0), 0),
         moderation_total_images = GREATEST(COALESCE(p_total_images, 0), 0),
         moderation_error = NULLIF(btrim(COALESCE(p_error, '')), ''),
         moderation_attempts = v_item.moderation_attempts + 1,
         moderated_at = now()
   WHERE id = p_content_id;

  RETURN jsonb_build_object(
    'applied', true,
    'content_id', p_content_id,
    'moderation_status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.apply_content_moderation_result(
  uuid, timestamptz, text, jsonb, text, integer, integer, text
) FROM PUBLIC, anon, authenticated;