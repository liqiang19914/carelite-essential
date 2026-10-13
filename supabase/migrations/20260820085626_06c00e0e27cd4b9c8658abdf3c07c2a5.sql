CREATE OR REPLACE FUNCTION public.get_platform_device_grants()
RETURNS TABLE(provider_key text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT g.provider_key
  FROM public.oem_device_grants g
  WHERE g.manager_id = '00000000-0000-0000-0000-00000000a001'::uuid
    AND g.grant_status = 'granted'
    AND g.is_enabled = true
  ORDER BY g.provider_key;
$function$;

REVOKE ALL ON FUNCTION public.get_platform_device_grants() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_platform_device_grants() TO anon, authenticated;

COMMENT ON FUNCTION public.get_platform_device_grants() IS '平台自有小程序的设备授权公开读口：只返回已授权且已启用的 provider_key，供终端用户判定「开始测量」入口；绝不暴露 provider_config 厂商凭证。';