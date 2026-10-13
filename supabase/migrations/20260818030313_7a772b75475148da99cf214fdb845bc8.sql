-- ── 内部清洗 helper：按长度截断并把空串归一成 NULL ───────────────────────
CREATE OR REPLACE FUNCTION public._brand_docs_clean_text(p_value text, p_max int)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT NULLIF(left(btrim(COALESCE(p_value, '')), p_max), '');
$function$;

-- 轮播文案清洗：最多 5 条，每条 title 必填，icon/body 可空
CREATE OR REPLACE FUNCTION public._brand_docs_clean_slides(p_slides jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_item  jsonb;
  v_title text;
  v_out   jsonb := '[]'::jsonb;
BEGIN
  IF p_slides IS NULL OR jsonb_typeof(p_slides) <> 'array' THEN
    RETURN NULL;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_slides) LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      CONTINUE;
    END IF;
    v_title := public._brand_docs_clean_text(v_item->>'title', 30);
    IF v_title IS NULL THEN
      CONTINUE;
    END IF;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'icon',  COALESCE(public._brand_docs_clean_text(v_item->>'icon', 8), ''),
      'title', v_title,
      'body',  COALESCE(public._brand_docs_clean_text(v_item->>'body', 120), '')
    ));
    IF jsonb_array_length(v_out) >= 5 THEN
      EXIT;
    END IF;
  END LOOP;

  RETURN CASE WHEN jsonb_array_length(v_out) = 0 THEN NULL ELSE v_out END;
END;
$function$;

-- ── 商户读自己企业的配置（企业内任意 manager 可读，方便员工看到当前生效文案）──
CREATE OR REPLACE FUNCTION public.get_my_merchant_brand_docs()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_root     uuid;
  v_can_edit boolean;
  v_row      public.merchant_brand_docs%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END,
         (p.parent_manager_id IS NULL OR p.sub_role = 'admin')
    INTO v_root, v_can_edit
    FROM public.profiles p
   WHERE p.id = v_uid AND p.role = 'manager';

  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.merchant_brand_docs WHERE root_manager_id = v_root;

  RETURN jsonb_build_object(
    'root_manager_id',    v_root,
    'can_edit',           COALESCE(v_can_edit, false),
    'exists',             v_row.root_manager_id IS NOT NULL,
    'privacy_body',       v_row.privacy_body,
    'agreement_body',     v_row.agreement_body,
    'compliance_body',    v_row.compliance_body,
    'docs_updated_on',    v_row.docs_updated_on,
    'login_slogan',       v_row.login_slogan,
    'login_subtitle',     v_row.login_subtitle,
    'login_new_user_tip', v_row.login_new_user_tip,
    'login_slides',       v_row.login_slides,
    'icp_record',         v_row.icp_record,
    'app_version_label',  v_row.app_version_label,
    'updated_at',         v_row.updated_at
  );
END;
$function$;

-- ── 商户保存（仅企业老板 / 企业管理员）──────────────────────────────────
-- p_docs 只认白名单键；键存在即写入（可显式传 null 清空），键缺失则保留原值。
CREATE OR REPLACE FUNCTION public.save_my_merchant_brand_docs(p_docs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_root     uuid;
  v_can_edit boolean;
  v_old      public.merchant_brand_docs%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;
  IF p_docs IS NULL OR jsonb_typeof(p_docs) <> 'object' THEN
    RAISE EXCEPTION '提交的内容格式不正确' USING ERRCODE = '22023';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END,
         (p.parent_manager_id IS NULL OR p.sub_role = 'admin')
    INTO v_root, v_can_edit
    FROM public.profiles p
   WHERE p.id = v_uid AND p.role = 'manager';

  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF v_can_edit IS NOT TRUE THEN
    RAISE EXCEPTION '只有企业超级管理员或管理员可以修改协议正文与登录页文案' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_old FROM public.merchant_brand_docs WHERE root_manager_id = v_root;

  INSERT INTO public.merchant_brand_docs AS d (
    root_manager_id, privacy_body, agreement_body, compliance_body, docs_updated_on,
    login_slogan, login_subtitle, login_new_user_tip, login_slides,
    icp_record, app_version_label, updated_by, updated_at
  )
  VALUES (
    v_root,
    CASE WHEN p_docs ? 'privacy_body'    THEN public._brand_docs_clean_text(p_docs->>'privacy_body', 20000)    ELSE v_old.privacy_body END,
    CASE WHEN p_docs ? 'agreement_body'  THEN public._brand_docs_clean_text(p_docs->>'agreement_body', 20000)  ELSE v_old.agreement_body END,
    CASE WHEN p_docs ? 'compliance_body' THEN public._brand_docs_clean_text(p_docs->>'compliance_body', 20000) ELSE v_old.compliance_body END,
    CASE WHEN p_docs ? 'docs_updated_on'
         THEN NULLIF(btrim(COALESCE(p_docs->>'docs_updated_on', '')), '')::date
         ELSE v_old.docs_updated_on END,
    CASE WHEN p_docs ? 'login_slogan'       THEN public._brand_docs_clean_text(p_docs->>'login_slogan', 60)       ELSE v_old.login_slogan END,
    CASE WHEN p_docs ? 'login_subtitle'     THEN public._brand_docs_clean_text(p_docs->>'login_subtitle', 80)     ELSE v_old.login_subtitle END,
    CASE WHEN p_docs ? 'login_new_user_tip' THEN public._brand_docs_clean_text(p_docs->>'login_new_user_tip', 120) ELSE v_old.login_new_user_tip END,
    CASE WHEN p_docs ? 'login_slides'       THEN public._brand_docs_clean_slides(p_docs->'login_slides')          ELSE v_old.login_slides END,
    CASE WHEN p_docs ? 'icp_record'         THEN public._brand_docs_clean_text(p_docs->>'icp_record', 60)         ELSE v_old.icp_record END,
    CASE WHEN p_docs ? 'app_version_label'  THEN public._brand_docs_clean_text(p_docs->>'app_version_label', 30)  ELSE v_old.app_version_label END,
    v_uid, now()
  )
  ON CONFLICT (root_manager_id) DO UPDATE SET
    privacy_body       = EXCLUDED.privacy_body,
    agreement_body     = EXCLUDED.agreement_body,
    compliance_body    = EXCLUDED.compliance_body,
    docs_updated_on    = EXCLUDED.docs_updated_on,
    login_slogan       = EXCLUDED.login_slogan,
    login_subtitle     = EXCLUDED.login_subtitle,
    login_new_user_tip = EXCLUDED.login_new_user_tip,
    login_slides       = EXCLUDED.login_slides,
    icp_record         = EXCLUDED.icp_record,
    app_version_label  = EXCLUDED.app_version_label,
    updated_by         = EXCLUDED.updated_by,
    updated_at         = now();

  RETURN jsonb_build_object('success', true, 'root_manager_id', v_root);
END;
$function$;

-- ── 公开读（登录页 / 协议页渲染；anon 也要能读，未登录就要看到）─────────────
-- 不校验 OEM 小程序是否开通：商户专属链接与自定义域名进店同样要用自己的文案。
CREATE OR REPLACE FUNCTION public.get_public_merchant_brand_docs(p_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_row  public.merchant_brand_docs%ROWTYPE;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
    INTO v_root
    FROM public.profiles p
   WHERE p.id = p_manager_id
     AND p.role = 'manager'
     AND COALESCE(p.is_disabled, false) = false;

  IF v_root IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row FROM public.merchant_brand_docs WHERE root_manager_id = v_root;
  IF v_row.root_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'root_manager_id',    v_root,
    'privacy_body',       v_row.privacy_body,
    'agreement_body',     v_row.agreement_body,
    'compliance_body',    v_row.compliance_body,
    'docs_updated_on',    v_row.docs_updated_on,
    'login_slogan',       v_row.login_slogan,
    'login_subtitle',     v_row.login_subtitle,
    'login_new_user_tip', v_row.login_new_user_tip,
    'login_slides',       v_row.login_slides,
    'icp_record',         v_row.icp_record,
    'app_version_label',  v_row.app_version_label,
    'updated_at',         v_row.updated_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_merchant_brand_docs(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_merchant_brand_docs() TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_my_merchant_brand_docs(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_merchant_brand_docs(uuid) TO anon, authenticated;