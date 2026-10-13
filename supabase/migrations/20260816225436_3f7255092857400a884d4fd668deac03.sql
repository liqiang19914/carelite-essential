-- ============================================================================
-- 商户自定义短信签名：manager_sms_configs 表 + 商户配置/平台审核 RPC
-- 归属 root_manager_id；每企业一条；status pending→approved 由平台审核后生效。
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.manager_sms_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL UNIQUE REFERENCES public.managers(id) ON DELETE CASCADE,
  sign_name text NOT NULL CHECK (char_length(sign_name) BETWEEN 1 AND 20),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  review_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_manager_sms_configs_root
  ON public.manager_sms_configs (root_manager_id);

ALTER TABLE public.manager_sms_configs ENABLE ROW LEVEL SECURITY;

-- 表不直接授权，全走 SECURITY DEFINER RPC
REVOKE ALL ON public.manager_sms_configs FROM anon, authenticated;

-- 商户：读自己企业的短信签名配置
CREATE OR REPLACE FUNCTION public.list_my_sms_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  RETURN (
    SELECT to_jsonb(c)
    FROM (
      SELECT id, root_manager_id, sign_name, status, review_note, created_at, updated_at
      FROM public.manager_sms_configs
      WHERE root_manager_id = v_root
    ) c
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_sms_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_sms_config() TO authenticated;

-- 商户：保存签名（新建或修改都回退到 pending，需平台重新审核）
CREATE OR REPLACE FUNCTION public.save_my_sms_config(p_sign_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_sign text;
  v_id uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  v_sign := btrim(COALESCE(p_sign_name, ''));
  IF char_length(v_sign) < 1 OR char_length(v_sign) > 20 THEN
    RAISE EXCEPTION '签名长度需在 1-20 个字符之间' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.manager_sms_configs (root_manager_id, sign_name, status, review_note)
  VALUES (v_root, v_sign, 'pending', NULL)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET sign_name = EXCLUDED.sign_name,
        status = 'pending',
        review_note = NULL,
        updated_at = now()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'sign_name', v_sign, 'status', 'pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_sms_config(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_my_sms_config(text) TO authenticated;

-- 平台：列出全部商户短信签名配置（含商户名，供审核）
CREATE OR REPLACE FUNCTION public.admin_list_sms_configs()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT c.id,
           c.root_manager_id,
           c.sign_name,
           c.status,
           c.review_note,
           c.created_at,
           c.updated_at,
           COALESCE(NULLIF(m.business_name, ''), NULLIF(m.company_name, ''), m.id::text) AS merchant_name
    FROM public.manager_sms_configs c
    JOIN public.managers m ON m.id = c.root_manager_id
  ) r;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_sms_configs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_sms_configs() TO authenticated;

-- 平台：审核商户短信签名（approved / rejected / pending）
CREATE OR REPLACE FUNCTION public.admin_set_sms_config_status(p_root_manager_id uuid, p_status text, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_status text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('approved','rejected','pending') THEN
    RAISE EXCEPTION '不支持的状态' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.manager_sms_configs
     SET status = p_status,
         review_note = btrim(COALESCE(p_note, '')),
         updated_at = now()
   WHERE root_manager_id = p_root_manager_id
   RETURNING status INTO v_status;

  IF v_status IS NULL THEN
    RAISE EXCEPTION '该商户还没有提交短信签名' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('root_manager_id', p_root_manager_id, 'status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_sms_config_status(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_sms_config_status(uuid, text, text) TO authenticated;