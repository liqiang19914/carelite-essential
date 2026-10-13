-- 渠道推广：落地任务墙（landing_enabled + wecom_qr + task 跟踪）。
-- 商户可以为每个渠道配置：是否开启任务墙、企微好友二维码图片、访客完成任务的记录。

ALTER TABLE public.merchant_channels
  ADD COLUMN IF NOT EXISTS landing_enabled boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS wecom_qr_image_url text;

-- 渠道任务完成记录：一个访客（匿名 visitor_key 或登录 user_id）一个渠道一项任务记一条。
-- 登录态 user_id 存在时 visitor_key 也冗余存一份，便于匿名→登录后关联。
CREATE TABLE IF NOT EXISTS public.merchant_channel_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_code text NOT NULL REFERENCES public.merchant_channels(code) ON DELETE CASCADE,
  visitor_key text,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  task_name text NOT NULL CHECK (task_name IN ('wecom_qr', 'phone_auth', 'company_info')),
  extra jsonb,              -- 各任务可选的附加信息：company_info 的表单内容、phone_auth 的脱敏手机号等
  completed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mch_channel_tasks_code_visitor
  ON public.merchant_channel_tasks(channel_code, visitor_key);
CREATE INDEX IF NOT EXISTS idx_mch_channel_tasks_code_user
  ON public.merchant_channel_tasks(channel_code, user_id);

-- 幂等记录任务完成：已完成不重复写入，未完成 INSERT
CREATE OR REPLACE FUNCTION public.mark_merchant_channel_task(
  p_channel_code text,
  p_task_name text,
  p_visitor_key text DEFAULT NULL,
  p_extra jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_existing int;
BEGIN
  -- 幂等检查：登录用户按 (channel_code, task_name, user_id) 判重；匿名按 visitor_key
  IF v_uid IS NOT NULL THEN
    SELECT count(*) INTO v_existing
    FROM public.merchant_channel_tasks
    WHERE channel_code = p_channel_code
      AND task_name = p_task_name
      AND user_id = v_uid;
  ELSIF p_visitor_key IS NOT NULL THEN
    SELECT count(*) INTO v_existing
    FROM public.merchant_channel_tasks
    WHERE channel_code = p_channel_code
      AND task_name = p_task_name
      AND visitor_key = p_visitor_key;
  END IF;

  IF COALESCE(v_existing, 0) = 0 THEN
    INSERT INTO public.merchant_channel_tasks(
      channel_code, visitor_key, user_id, task_name, extra
    ) VALUES (
      p_channel_code, p_visitor_key, v_uid, p_task_name, p_extra
    );
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_merchant_channel_task(text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_merchant_channel_task(text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_merchant_channel_task(text, text, text, jsonb) TO service_role;

-- 查询渠道落地配置（给 H5 任务墙用）：渠道信息 + 商户品牌名 + 已完成任务
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

  -- 商户品牌名：从 enterprise_settings 或 merchant_profiles 取（任意一处有即可）
  v_root := v_channel->>'root_manager_id';
  SELECT COALESCE(
    (SELECT value->>'brand_name' FROM public.enterprise_settings WHERE root_manager_id = v_root LIMIT 1),
    (SELECT display_name FROM public.merchant_profiles WHERE root_manager_id = v_root LIMIT 1),
    ''
  ) INTO v_brand_name;

  -- 已完成任务：登录用户用 auth.uid()，匿名用 visitor_key
  IF auth.uid() IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (
      SELECT DISTINCT task_name FROM public.merchant_channel_tasks
      WHERE channel_code = p_code AND user_id = auth.uid()
    ) sub;
  ELSIF p_visitor_key IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (
      SELECT DISTINCT task_name FROM public.merchant_channel_tasks
      WHERE channel_code = p_code AND visitor_key = p_visitor_key
    ) sub;
  ELSE
    v_done := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'channel', jsonb_build_object(
      'code', v_channel->>'code',
      'name', v_channel->>'name',
      'landing_enabled', COALESCE((v_channel->>'landing_enabled')::boolean, true),
      'wecom_qr_image_url', v_channel->>'wecom_qr_image_url'
    ),
    'brand', jsonb_build_object('name', v_brand_name),
    'completed_tasks', v_done
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_channel_landing(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_landing(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_landing(text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
