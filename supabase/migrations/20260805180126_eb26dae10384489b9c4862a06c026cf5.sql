-- 商户内容中心：画册页写入校验 + 画册变动打回重检

-- 1. 子行写入：校验父项存在、是画册、同企业；回填归属与审计列
CREATE OR REPLACE FUNCTION public.manager_content_album_pages_before_write()
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
  v_parent_root uuid;
  v_parent_type text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.content_id IS DISTINCT FROM OLD.content_id THEN
    RAISE EXCEPTION '不能把画册页移动到其他内容' USING ERRCODE = '22023';
  END IF;

  SELECT root_manager_id, content_type
    INTO v_parent_root, v_parent_type
  FROM public.manager_content_items
  WHERE id = NEW.content_id;

  IF v_parent_root IS NULL THEN
    RAISE EXCEPTION '所属画册不存在，请刷新后重试' USING ERRCODE = 'P0002';
  END IF;

  IF v_parent_type <> 'album' THEN
    RAISE EXCEPTION '只有画册可以添加图片页' USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_admin AND NOT v_is_service
     AND (
       NOT public.is_active_enterprise_content_member(v_uid)
       OR v_parent_root IS DISTINCT FROM
          public.get_enterprise_root_manager_id(v_uid)
     ) THEN
    RAISE EXCEPTION '你无权修改该画册' USING ERRCODE = '42501';
  END IF;

  NEW.root_manager_id := v_parent_root;
  NEW.updated_by := COALESCE(v_uid, OLD.updated_by);
  NEW.updated_at := now();

  IF TG_OP = 'INSERT' THEN
    NEW.created_by := v_uid;
    NEW.created_at := now();
  ELSE
    NEW.created_by := OLD.created_by;
    NEW.created_at := OLD.created_at;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS manager_content_album_pages_before_write_trg
  ON public.manager_content_album_pages;
CREATE TRIGGER manager_content_album_pages_before_write_trg
BEFORE INSERT OR UPDATE ON public.manager_content_album_pages
FOR EACH ROW
EXECUTE FUNCTION public.manager_content_album_pages_before_write();

-- 2. 画册页增删或实质变化 → 父项打回待检测（保留 requires_manual_review 与 is_published）
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
         moderation_attempts = 0,
         moderated_at = NULL
   WHERE id = v_content_id
     AND moderation_status <> 'pending';

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS manager_content_album_pages_reset_moderation_trg
  ON public.manager_content_album_pages;
CREATE TRIGGER manager_content_album_pages_reset_moderation_trg
AFTER INSERT OR UPDATE OR DELETE ON public.manager_content_album_pages
FOR EACH ROW
EXECUTE FUNCTION public.reset_content_moderation_on_album_page_change();