-- 称重 AI 解读专属智能体：按企业根商户一份配置。
-- weighing_manager_id 为空 = 未指定（客户端回退平台小凯）；
-- 被指定的健管师被删除时 FK 自动置空，同样回退小凯。
CREATE TABLE IF NOT EXISTS public.merchant_weighing_ai_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  weighing_manager_id uuid REFERENCES public.managers(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_weighing_ai_settings IS
  '称重 AI 解读智能体配置：root_manager_id 按企业根商户一行，weighing_manager_id 为空=回退平台小凯';
COMMENT ON COLUMN public.merchant_weighing_ai_settings.weighing_manager_id IS
  '承接称重 AI 解读的本企业健管师；NULL=未指定（回退平台小凯）；健管师删除时自动置空';

ALTER TABLE public.merchant_weighing_ai_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_weighing_ai_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weighing_ai_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weighing_ai_settings TO service_role;

-- 企业客户判定：该用户是否与企业（根健管师）名下任一健管师存在 active 客户关系。
-- EF 鉴权用：商户指定健管师承接称重解读时，客户无需与该健管师逐条建立关系，
-- 只要属于这家企业的客户即可。
CREATE OR REPLACE FUNCTION public.is_enterprise_client(p_root_manager_id uuid, p_client_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.client_relations cr
    WHERE cr.client_id = p_client_user_id
      AND cr.status = 'active'
      AND public.get_enterprise_root_manager_id(cr.manager_id) = p_root_manager_id
  );
$function$;

REVOKE ALL ON FUNCTION public.is_enterprise_client(uuid, uuid) FROM PUBLIC;

-- 商户后台读自己的配置
CREATE OR REPLACE FUNCTION public.get_merchant_weighing_ai_setting()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_weighing_ai_settings%ROWTYPE;
  v_name text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT * INTO v_row
  FROM public.merchant_weighing_ai_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND OR v_row.weighing_manager_id IS NULL THEN
    RETURN jsonb_build_object('weighing_manager_id', NULL, 'weighing_manager_name', NULL);
  END IF;

  -- 被指定的健管师可能已不属于本企业（数据漂移），此时按未指定处理
  IF public.get_enterprise_root_manager_id(v_row.weighing_manager_id) IS DISTINCT FROM v_root THEN
    RETURN jsonb_build_object('weighing_manager_id', NULL, 'weighing_manager_name', NULL);
  END IF;

  SELECT COALESCE(m.partner_card_display_name, p.nickname, '健康管理师')
    INTO v_name
    FROM public.managers m
    LEFT JOIN public.profiles p ON p.id = m.id
    WHERE m.id = v_row.weighing_manager_id;

  RETURN jsonb_build_object(
    'weighing_manager_id', v_row.weighing_manager_id,
    'weighing_manager_name', COALESCE(v_name, '健康管理师')
  );
END;
$function$;

-- 商户后台保存：NULL=不指定（回退小凯）；非空必须是本企业健管师
CREATE OR REPLACE FUNCTION public.save_merchant_weighing_ai_setting(p_weighing_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可保存，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  IF p_weighing_manager_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.managers m
      WHERE m.id = p_weighing_manager_id
        AND public.get_enterprise_root_manager_id(m.id) = v_root
    ) THEN
      RAISE EXCEPTION '只能选择本企业的健康管理师' USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO public.merchant_weighing_ai_settings
    (root_manager_id, weighing_manager_id, updated_by, updated_at)
  VALUES (v_root, p_weighing_manager_id, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET weighing_manager_id = EXCLUDED.weighing_manager_id,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

-- 客户侧公开读取：未配置/健管师已删除或不可用 → NULL（客户端回退平台小凯）
CREATE OR REPLACE FUNCTION public.get_public_merchant_weighing_ai_manager(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_weighing_ai_settings%ROWTYPE;
  v_name text;
  v_avatar text;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_weighing_ai_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND OR v_row.weighing_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(m.partner_card_display_name, p.nickname, '健康管理师'),
         COALESCE(m.avatar_url, p.avatar_url)
    INTO v_name, v_avatar
    FROM public.managers m
    LEFT JOIN public.profiles p ON p.id = m.id
    WHERE m.id = v_row.weighing_manager_id
      AND p.is_disabled IS NOT TRUE
      AND public.get_enterprise_root_manager_id(m.id) = p_root_manager_id;

  IF v_name IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'manager_id', v_row.weighing_manager_id,
    'display_name', v_name,
    'avatar_url', v_avatar
  );
END;
$function$;

-- 授权面：读写只给 authenticated；公开读给 anon/authenticated
REVOKE ALL ON FUNCTION public.get_merchant_weighing_ai_setting() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_weighing_ai_setting() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_weighing_ai_setting(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_weighing_ai_setting(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_merchant_weighing_ai_manager(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_merchant_weighing_ai_manager(uuid) TO anon, authenticated;