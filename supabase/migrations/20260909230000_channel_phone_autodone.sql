-- 渠道任务墙：已登录用户（必然已验证手机号）phone_auth 任务视同完成；
-- 登录分支同时合并该用户匿名阶段（visitor_key）做过的任务，避免登录前后任务态丢失。

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
    -- 登录用户：合并 user_id 维度 + 同次访问 visitor_key 维度的任务记录；
    -- profiles.phone 非空说明该账号已验证手机号（登录方式即手机号验证码），
    -- phone_auth 任务直接视同完成，任务墙不再让已登录用户重复授权。
    SELECT COALESCE(jsonb_agg(DISTINCT task_name), '[]'::jsonb) INTO v_done
    FROM (
      SELECT task_name FROM public.merchant_channel_tasks
      WHERE channel_code = p_code
        AND (
          user_id = auth.uid()
          OR (p_visitor_key IS NOT NULL AND visitor_key = p_visitor_key)
        )
      UNION
      SELECT 'phone_auth'::text
      WHERE EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND COALESCE(btrim(phone), '') <> ''
      )
    ) sub;
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

NOTIFY pgrst, 'reload schema';
