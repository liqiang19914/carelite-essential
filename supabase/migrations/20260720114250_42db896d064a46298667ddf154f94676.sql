-- 消息通知开关持久化(完全复刻 privacy_settings 的模式):
-- 新增 profiles.notification_settings jsonb NOT NULL DEFAULT '{}'。
-- CHECK 保证只能是 object(与 privacy_settings 一致)。
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS notification_settings jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE n.nspname = 'public' AND t.relname = 'profiles'
       AND c.conname = 'profiles_notification_settings_is_object'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_notification_settings_is_object
      CHECK (jsonb_typeof(notification_settings) = 'object');
  END IF;
END $$;

COMMENT ON COLUMN public.profiles.notification_settings IS
  'User notification toggle preferences (/user/notifications page). JSON object with boolean values keyed by whitelisted notification category id (health, consult, survey, system). Missing keys fall back to service-layer defaults. Persistence-only this round — real notification event pipeline is a separate future feature.';

-- 原子按键更新单个通知开关。签名和实现完全类比 update_my_privacy_setting。
-- 4 键白名单(health/consult/survey/system)对应 UserNotifications 页面上的 4 个开关。
CREATE OR REPLACE FUNCTION public.update_my_notification_setting(
  p_user_id uuid,
  p_key text,
  p_enabled boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;
  IF p_key NOT IN ('health', 'consult', 'survey', 'system') THEN
    RAISE EXCEPTION 'invalid notification setting key: %', p_key USING ERRCODE = '22023';
  END IF;
  UPDATE public.profiles
     SET notification_settings = jsonb_set(
           COALESCE(notification_settings, '{}'::jsonb),
           ARRAY[p_key],
           to_jsonb(p_enabled),
           true
         ),
         updated_at = NOW()
   WHERE id = p_user_id
   RETURNING notification_settings INTO v_result;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'profile not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_notification_setting(uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_my_notification_setting(uuid, text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_my_notification_setting(uuid, text, boolean) TO authenticated;