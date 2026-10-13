-- 1) Add privacy_settings jsonb column to profiles (idempotent)
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS privacy_settings jsonb NOT NULL DEFAULT '{}'::jsonb;

-- 2) Constrain the column to hold only JSON objects (not array, not primitive, not null-json)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE n.nspname = 'public'
       AND t.relname = 'profiles'
       AND c.conname = 'profiles_privacy_settings_is_object'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_privacy_settings_is_object
      CHECK (jsonb_typeof(privacy_settings) = 'object');
  END IF;
END $$;

-- 3) Atomic single-key updater RPC
CREATE OR REPLACE FUNCTION public.update_my_privacy_setting(
  p_user_id uuid,
  p_key text,
  p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  -- Caller must be authenticated and updating their own profile
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  -- Whitelist the four known keys; unknown keys are rejected
  IF p_key NOT IN ('share_records', 'share_vitals', 'show_phone', 'data_analysis') THEN
    RAISE EXCEPTION 'invalid privacy setting key: %', p_key
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
     SET privacy_settings = jsonb_set(
                              COALESCE(privacy_settings, '{}'::jsonb),
                              ARRAY[p_key],
                              to_jsonb(p_enabled),
                              true
                            ),
         updated_at = NOW()
   WHERE id = p_user_id
   RETURNING privacy_settings INTO v_result;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'profile not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_result;
END;
$$;

-- 4) Lock down execute privileges
REVOKE ALL ON FUNCTION public.update_my_privacy_setting(uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_my_privacy_setting(uuid, text, boolean) TO authenticated;

COMMENT ON COLUMN public.profiles.privacy_settings IS
  'User privacy toggle preferences. JSON object with boolean values keyed by whitelisted setting id (share_records, share_vitals, show_phone, data_analysis). Missing keys fall back to service-layer defaults.';

COMMENT ON FUNCTION public.update_my_privacy_setting(uuid, text, boolean) IS
  'Atomically update a single whitelisted key inside profiles.privacy_settings for the calling user. SECURITY INVOKER; verifies auth.uid() = p_user_id and rejects unknown keys.';