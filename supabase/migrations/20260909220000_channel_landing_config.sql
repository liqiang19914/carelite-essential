-- 1. landing_config：落地页文案（品牌名 / 欢迎标题 / 副标题 / 进入按钮）
ALTER TABLE public.merchant_channels
  ADD COLUMN IF NOT EXISTS landing_config jsonb NOT NULL DEFAULT '{}'::jsonb;

-- 2. create_merchant_channel：加 p_landing_config 参数
CREATE OR REPLACE FUNCTION public.create_merchant_channel(
  p_name text,
  p_category text DEFAULT 'other',
  p_target_page text DEFAULT 'pages/index/index',
  p_remark text DEFAULT NULL,
  p_root_manager_id uuid DEFAULT NULL,
  p_landing_tasks jsonb DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL,
  p_landing_config jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid := COALESCE(p_root_manager_id, public.get_enterprise_root_manager_id(auth.uid()));
  v_code text;
BEGIN
  IF v_root IS NULL THEN RAISE EXCEPTION '未登录或无企业归属' USING ERRCODE = '28000'; END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION '渠道名称不能为空' USING ERRCODE = '23505'; END IF;

  v_code := public.generate_short_code(8);
  WHILE EXISTS (SELECT 1 FROM public.merchant_channels WHERE code = v_code) LOOP
    v_code := public.generate_short_code(8);
  END LOOP;

  INSERT INTO public.merchant_channels (
    code, name, category, target_page, remark, root_manager_id,
    landing_tasks, wecom_qr_image_url, landing_config
  ) VALUES (
    v_code, btrim(p_name), COALESCE(p_category, 'other'),
    COALESCE(p_target_page, 'pages/index/index'), p_remark, v_root,
    COALESCE(p_landing_tasks, '[]'::jsonb), p_wecom_qr_image_url,
    COALESCE(p_landing_config, '{}'::jsonb)
  );

  RETURN public.get_merchant_channel_for_code(v_code);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb) TO service_role;

-- 3. update_merchant_channel：加 p_landing_config
CREATE OR REPLACE FUNCTION public.update_merchant_channel(
  p_code text,
  p_name text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_target_page text DEFAULT NULL,
  p_remark text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_landing_tasks jsonb DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL,
  p_landing_config jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public.get_enterprise_root_manager_id(auth.uid());
  v_count int;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.merchant_channels WHERE code = p_code AND root_manager_id = v_root
  ) THEN RAISE EXCEPTION '渠道不存在或无权限' USING ERRCODE = '42501'; END IF;

  UPDATE public.merchant_channels c SET
    name = COALESCE(p_name, c.name),
    category = COALESCE(p_category, c.category),
    target_page = COALESCE(p_target_page, c.target_page),
    remark = COALESCE(p_remark, c.remark),
    is_active = COALESCE(p_is_active, c.is_active),
    landing_tasks = COALESCE(p_landing_tasks, c.landing_tasks),
    wecom_qr_image_url = COALESCE(p_wecom_qr_image_url, c.wecom_qr_image_url),
    landing_config = COALESCE(p_landing_config, c.landing_config),
    updated_at = now()
  WHERE c.code = p_code;

  RETURN public.get_merchant_channel_for_code(p_code);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_merchant_channel(text, text, text, text, boolean, jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text, text, text, text, boolean, jsonb, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text, text, text, text, boolean, jsonb, text, jsonb) TO service_role;

-- 4. get_merchant_channel_landing：返回 landing_tasks + landing_config（H5 任务墙需要）
CREATE OR REPLACE FUNCTION public.get_merchant_channel_landing(
  p_code text,
  p_visitor_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_channel jsonb;
  v_brand_name text;
  v_done jsonb;
BEGIN
  SELECT to_jsonb(c) INTO v_channel
  FROM public.merchant_channels c
  WHERE c.code = p_code AND c.is_active = true;

  IF v_channel IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
  END IF;

  v_root := v_channel->>'root_manager_id';
  SELECT COALESCE(m.brand_name, m.app_name, '') INTO v_brand_name
  FROM public.manager_miniprograms m
  WHERE m.manager_id = v_root AND m.is_enabled = true
  LIMIT 1;

  IF auth.uid() IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (SELECT DISTINCT task_name FROM public.merchant_channel_tasks
          WHERE channel_code = p_code AND user_id = auth.uid()) sub;
  ELSIF p_visitor_key IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (SELECT DISTINCT task_name FROM public.merchant_channel_tasks
          WHERE channel_code = p_code AND visitor_key = p_visitor_key) sub;
  ELSE
    v_done := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'skip', COALESCE(jsonb_array_length(COALESCE(v_channel->'landing_tasks', '[]'::jsonb)), 0) = 0,
    'channel', jsonb_build_object(
      'code', v_channel->>'code',
      'name', v_channel->>'name',
      'landing_enabled', COALESCE((v_channel->>'landing_enabled')::boolean, true),
      'landing_tasks', COALESCE(v_channel->'landing_tasks', '[]'::jsonb),
      'landing_config', COALESCE(v_channel->'landing_config', '{}'::jsonb),
      'wecom_qr_image_url', v_channel->>'wecom_qr_image_url'
    ),
    'brand', jsonb_build_object('name', v_brand_name),
    'completed_tasks', v_done
  );
END;
$function$;

-- 5. list / get_for_code RPC 也返回 landing_config（B 端 Dialog 需要）
CREATE OR REPLACE FUNCTION public.get_merchant_channel_for_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_channels;
BEGIN
  SELECT * INTO v_row FROM public.merchant_channels WHERE code = p_code LIMIT 1;
  IF v_row IS NULL THEN RETURN NULL; END IF;
  RETURN row_to_json(v_row)::jsonb;
END;
$function$;

NOTIFY pgrst, 'reload schema';
