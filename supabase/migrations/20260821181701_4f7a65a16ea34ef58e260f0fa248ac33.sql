-- ============================================================
-- 审查修复 6：is_system_default / system_default_key / is_platform_root
-- 三个内部标记仅平台服务可写，商户不可篡改
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_system_manager_flags()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF auth.role() IS NOT NULL AND auth.role() <> 'service_role' THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.is_system_default
         OR NEW.is_platform_root
         OR NEW.system_default_key IS NOT NULL THEN
        RAISE EXCEPTION '系统健管师标记仅平台服务可写' USING ERRCODE = '42501';
      END IF;
    ELSE
      IF NEW.is_system_default IS DISTINCT FROM OLD.is_system_default
         OR NEW.is_platform_root IS DISTINCT FROM OLD.is_platform_root
         OR NEW.system_default_key IS DISTINCT FROM OLD.system_default_key THEN
        RAISE EXCEPTION '系统健管师标记仅平台服务可写' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_system_manager_flags ON public.managers;
CREATE TRIGGER trg_protect_system_manager_flags
  BEFORE INSERT OR UPDATE OF is_system_default, system_default_key, is_platform_root ON public.managers
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_system_manager_flags();