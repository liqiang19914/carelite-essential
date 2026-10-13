-- 修正：自动检测服务以 service_role 写回机检结果，此时 auth.uid() 为 NULL，
-- 原触发器会把它当成越权访问直接拒掉。这里显式放行 service_role。
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
    NEW.moderation_attempts := 0;
    NEW.moderated_at := NULL;
  END IF;

  NEW.updated_by := COALESCE(v_uid, OLD.updated_by);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;