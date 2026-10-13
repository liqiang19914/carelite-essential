CREATE OR REPLACE FUNCTION public.manager_content_items_before_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- 统计字段-only 更新（阅读量/点赞量/顶置）不涉及内容本体，直接放行：
  -- 这些字段分别由公开计数（view_count）、点赞 RPC（like_count）、顶置 RPC（is_pinned/pinned_rank）维护，
  -- 触发器的权限校验面向「内容本体编辑」，不该拦它们。
  IF (NEW.view_count IS DISTINCT FROM OLD.view_count
      OR NEW.like_count IS DISTINCT FROM OLD.like_count
      OR NEW.is_pinned IS DISTINCT FROM OLD.is_pinned
      OR NEW.pinned_rank IS DISTINCT FROM OLD.pinned_rank)
     AND NEW.title IS NOT DISTINCT FROM OLD.title
     AND NEW.cover_url IS NOT DISTINCT FROM OLD.cover_url
     AND NEW.cover_storage_key IS NOT DISTINCT FROM OLD.cover_storage_key
     AND NEW.article_doc IS NOT DISTINCT FROM OLD.article_doc
     AND NEW.root_manager_id IS NOT DISTINCT FROM OLD.root_manager_id
     AND NEW.content_type IS NOT DISTINCT FROM OLD.content_type
     AND NEW.is_published IS NOT DISTINCT FROM OLD.is_published
     AND NEW.moderation_status IS NOT DISTINCT FROM OLD.moderation_status THEN
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
$function$;