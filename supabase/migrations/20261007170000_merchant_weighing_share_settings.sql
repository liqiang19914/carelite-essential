-- 商户级称重分享设置：按企业根一行，控制客户称重页的分享入口（转发卡片 / 生成海报）
-- enable_forward=true  → 称重页显示「转发」按钮 + 海报弹窗「转发给好友」按钮
-- enable_poster=true   → 称重页显示「生成海报」按钮
-- 至少开一个（save RPC 内校验）；未配置行时两个都开，保持向下兼容
CREATE TABLE IF NOT EXISTS public.merchant_weighing_share_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  enable_forward boolean NOT NULL DEFAULT true,
  enable_poster boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_weighing_share_settings IS
  '商户级称重分享设置：root_manager_id 按企业根一行；enable_forward 控制转发小程序卡片入口，enable_poster 控制生成海报入口，至少开一个';

ALTER TABLE public.merchant_weighing_share_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_weighing_share_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weighing_share_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weighing_share_settings TO service_role;

CREATE OR REPLACE FUNCTION public.get_merchant_weighing_share_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_weighing_share_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT * INTO v_row
  FROM public.merchant_weighing_share_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('enable_forward', true, 'enable_poster', true);
  END IF;

  RETURN jsonb_build_object('enable_forward', v_row.enable_forward, 'enable_poster', v_row.enable_poster);
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_merchant_weighing_share_settings(
  p_enable_forward boolean,
  p_enable_poster boolean
)
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
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以修改称重分享设置' USING ERRCODE = '42501';
  END IF;
  IF p_enable_forward IS NULL OR p_enable_poster IS NULL THEN
    RAISE EXCEPTION '分享开关不能为空' USING ERRCODE = '22023';
  END IF;
  IF NOT p_enable_forward AND NOT p_enable_poster THEN
    RAISE EXCEPTION '至少保留一种分享方式（转发卡片或生成海报）' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  INSERT INTO public.merchant_weighing_share_settings
    (root_manager_id, enable_forward, enable_poster, updated_by, updated_at)
  VALUES (v_root, p_enable_forward, p_enable_poster, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET enable_forward = EXCLUDED.enable_forward,
        enable_poster = EXCLUDED.enable_poster,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_public_weighing_share_settings(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_weighing_share_settings%ROWTYPE;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_weighing_share_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('enable_forward', true, 'enable_poster', true);
  END IF;

  RETURN jsonb_build_object('enable_forward', v_row.enable_forward, 'enable_poster', v_row.enable_poster);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_weighing_share_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_weighing_share_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_weighing_share_settings(boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_weighing_share_settings(boolean, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_weighing_share_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_weighing_share_settings(uuid) TO anon, authenticated;
