-- 审查修复（464/465/466）：profiles.wechat_unionid 加写入门禁
-- 登录用户经 PostgREST 直接 PATCH 本人 profiles 行的 wechat_unionid 可冒认关联任意商户客户；
-- 正规写入路径（wecom-unionid-backfill / wechat-oauth / prod-wechat-oauth）都走 service_role 客户端。
-- 加 BEFORE 守卫触发器：UPDATE 时 unionid 变化须命中 set_config 转义开关或特权角色；
-- INSERT 时仅拒绝非空 unionid 的非特权写入（空值插入不受影响）。

CREATE OR REPLACE FUNCTION public.guard_profiles_wechat_unionid_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_role text := auth.role();
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.wechat_unionid IS NOT NULL AND NEW.wechat_unionid <> '' THEN
      IF current_setting('app.allow_unionid_write', true) = 'on'
         OR v_role IS NULL OR v_role = 'service_role' OR v_role = 'supabase_auth_admin' THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION '微信身份由系统管理，不支持手动修改' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.wechat_unionid IS DISTINCT FROM OLD.wechat_unionid THEN
    IF current_setting('app.allow_unionid_write', true) = 'on'
       OR v_role IS NULL OR v_role = 'service_role' OR v_role = 'supabase_auth_admin' THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION '微信身份由系统管理，不支持手动修改' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.guard_profiles_wechat_unionid_write() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_profiles_wechat_unionid ON public.profiles;
CREATE TRIGGER trg_guard_profiles_wechat_unionid
BEFORE INSERT OR UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.guard_profiles_wechat_unionid_write();