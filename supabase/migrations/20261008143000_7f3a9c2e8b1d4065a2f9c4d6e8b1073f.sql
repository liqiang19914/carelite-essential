-- W3：HTML 包托管（site-bundle-import）需要的两个版本管理 RPC
-- 与 site_save_draft_schema 对应：bundle 版本由 Edge Function 两阶段写入
--   1) site_create_bundle_version：拿到 version_id 确定 OSS 前缀，manifest 先写 '{}'
--   2) site_update_bundle_manifest：全部资源上传成功后回写 manifest
-- 表级 trigger site_versions_type_guard 保证 html_bundle 行必须有 bundle_oss_prefix、schema 为空。

-- ─────────────────────────────────────────────────────────────────────────────
-- 7.10 创建 HTML 包草稿版本
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.site_create_bundle_version(
  p_site_id uuid,
  p_bundle_oss_prefix text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site public.merchant_sites%ROWTYPE;
  v_no int;
  v_version uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_site
  FROM public.merchant_sites
  WHERE id = p_site_id AND root_manager_id = v_root
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '站点不存在' USING ERRCODE = 'P0002';
  END IF;

  IF btrim(COALESCE(p_bundle_oss_prefix, '')) = '' THEN
    RAISE EXCEPTION '存储前缀不能为空' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(max(version_no), 0) + 1 INTO v_no
    FROM public.merchant_site_versions WHERE site_id = v_site.id;

  INSERT INTO public.merchant_site_versions
    (site_id, version_no, source_type, schema, bundle_oss_prefix, manifest, source, created_by)
  VALUES (
    v_site.id, v_no, 'html_bundle', NULL,
    btrim(p_bundle_oss_prefix),
    '{}'::jsonb,
    'upload', auth.uid()
  )
  RETURNING id INTO v_version;

  UPDATE public.merchant_sites
     SET draft_version_id = v_version, source_type = 'html_bundle', updated_at = now()
   WHERE id = v_site.id;

  RETURN jsonb_build_object('id', v_version, 'versionNo', v_no, 'reviewStatus', 'none');
END;
$function$;

REVOKE ALL ON FUNCTION public.site_create_bundle_version(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_create_bundle_version(uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7.11 回写 bundle manifest（上传完成后调用；仅本人站点的草稿版本可写）
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.site_update_bundle_manifest(
  p_version_id uuid,
  p_manifest jsonb
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site_id uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_manifest) <> 'object' THEN
    RAISE EXCEPTION 'manifest 结构不合法' USING ERRCODE = 'P0002';
  END IF;

  SELECT v.site_id INTO v_site_id
  FROM public.merchant_site_versions v
  JOIN public.merchant_sites s ON s.id = v.site_id
  WHERE v.id = p_version_id AND s.root_manager_id = v_root;

  IF v_site_id IS NULL THEN
    RAISE EXCEPTION '版本不存在' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.merchant_site_versions
     SET manifest = p_manifest
   WHERE id = p_version_id AND source_type = 'html_bundle';

  RETURN FOUND;
END;
$function$;

REVOKE ALL ON FUNCTION public.site_update_bundle_manifest(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_update_bundle_manifest(uuid, jsonb) TO authenticated;
