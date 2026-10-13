
-- 修复 protect_digital_persona_binding 触发器：
-- 之前用的 current_setting('request.jwt.claim.role', true) 是旧版 PostgREST 的单值 claim 接口，
-- 在当前 Supabase PostgREST 版本已废弃、只返回 NULL，导致 EF 用 SERVICE_ROLE_KEY 建的客户端
-- 也被误判为"非 service_role"、被触发器 42501 拒。
-- 改成项目其他 4 处防篡改都在用的 auth.role()（Supabase 官方 helper），风格对齐、行为正确。

CREATE OR REPLACE FUNCTION public.protect_digital_persona_binding()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_caller_role TEXT := auth.role();
  v_changed BOOLEAN := FALSE;
BEGIN
  -- service_role（EF 用）无条件放行
  IF v_caller_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.digital_persona_source_platform IS NOT NULL
       OR NEW.digital_persona_source_asset_id IS NOT NULL
       OR NEW.digital_persona_playback_url IS NOT NULL
       OR NEW.digital_persona_format IS NOT NULL
       OR NEW.digital_persona_status IS NOT NULL
       OR NEW.digital_persona_verified_at IS NOT NULL
       OR NEW.digital_persona_last_error IS NOT NULL THEN
      v_changed := TRUE;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.digital_persona_source_platform IS DISTINCT FROM OLD.digital_persona_source_platform
       OR NEW.digital_persona_source_asset_id IS DISTINCT FROM OLD.digital_persona_source_asset_id
       OR NEW.digital_persona_playback_url IS DISTINCT FROM OLD.digital_persona_playback_url
       OR NEW.digital_persona_format IS DISTINCT FROM OLD.digital_persona_format
       OR NEW.digital_persona_status IS DISTINCT FROM OLD.digital_persona_status
       OR NEW.digital_persona_verified_at IS DISTINCT FROM OLD.digital_persona_verified_at
       OR NEW.digital_persona_last_error IS DISTINCT FROM OLD.digital_persona_last_error THEN
      v_changed := TRUE;
    END IF;
  END IF;

  IF v_changed THEN
    RAISE EXCEPTION 'digital_persona binding fields are managed by server only; use partner-video-verify edge function'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;
