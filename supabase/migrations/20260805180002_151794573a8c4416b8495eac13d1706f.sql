-- 商户内容中心：父行写入与实质修改重检触发器
--
-- 这里补掉课程中心的一个漏洞：那边只在章节变动时退回审核，改父行标题/封面不退回，
-- 等于可以先拿一版温和文案过审再换内容。本触发器让父行实质字段变化也必须重新机检。
--
-- requires_manual_review 是安全钉子：只由平台人工下架置 true，编辑 / 重检 / 发布
-- 一律不清除，因此人工判断无法被商户改一个字绕过。

CREATE OR REPLACE FUNCTION public.manager_content_items_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean := COALESCE(public.is_admin(v_uid), false);
  v_material_changed boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT v_is_admin THEN
      IF NOT public.is_active_enterprise_content_member(v_uid) THEN
        RAISE EXCEPTION '所属企业当前不可使用内容管理，请联系企业负责人或平台处理'
          USING ERRCODE = '42501';
      END IF;
      NEW.root_manager_id := public.get_enterprise_root_manager_id(v_uid);
    ELSIF NEW.root_manager_id IS NULL THEN
      RAISE EXCEPTION '请选择内容所属企业' USING ERRCODE = '22023';
    END IF;

    -- 新内容一律从草稿态、未检测开始
    NEW.is_published := false;
    NEW.moderation_status := 'pending';
    NEW.moderation_labels := '[]'::jsonb;
    NEW.moderation_summary := NULL;
    NEW.moderation_checked_images := 0;
    NEW.moderation_total_images := 0;
    NEW.moderation_error := NULL;
    NEW.moderation_attempts := 0;
    NEW.moderated_at := NULL;
    NEW.requires_manual_review := false;
    NEW.takedown_note := NULL;
    NEW.taken_down_by := NULL;
    NEW.taken_down_at := NULL;
    NEW.created_by := v_uid;
    NEW.updated_by := v_uid;
    NEW.created_at := now();
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF NOT v_is_admin THEN
    IF NOT public.is_active_enterprise_content_member(v_uid)
       OR OLD.root_manager_id IS DISTINCT FROM
          public.get_enterprise_root_manager_id(v_uid) THEN
      RAISE EXCEPTION '你已无权修改该企业内容，请刷新页面或联系企业负责人'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- 归属与类型创建后不可变：省掉「资讯改成画册后正文怎么办」整类边界条件
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
    -- 打回待检测，清空上一轮机检结论；但保留 requires_manual_review 与 is_published
    NEW.moderation_status := 'pending';
    NEW.moderation_labels := '[]'::jsonb;
    NEW.moderation_summary := NULL;
    NEW.moderation_checked_images := 0;
    NEW.moderation_total_images := 0;
    NEW.moderation_error := NULL;
    NEW.moderation_attempts := 0;
    NEW.moderated_at := NULL;
  END IF;

  NEW.updated_by := v_uid;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS manager_content_items_before_write_trg
  ON public.manager_content_items;
CREATE TRIGGER manager_content_items_before_write_trg
BEFORE INSERT OR UPDATE ON public.manager_content_items
FOR EACH ROW
EXECUTE FUNCTION public.manager_content_items_before_write();