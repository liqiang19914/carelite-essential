CREATE OR REPLACE FUNCTION public.set_my_device_grant_enabled(
  p_provider_key text,
  p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_provider_key text := pg_catalog.btrim(p_provider_key);
  v_grant public.oem_device_grants%ROWTYPE;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'OEM_DEVICE_GRANT_AUTH_REQUIRED';
  END IF;

  IF v_provider_key IS NULL OR v_provider_key = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'OEM_DEVICE_GRANT_PROVIDER_REQUIRED';
  END IF;

  IF p_enabled IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22004', MESSAGE = 'OEM_DEVICE_GRANT_ENABLED_REQUIRED';
  END IF;

  SELECT g.* INTO v_grant
  FROM public.oem_device_grants AS g
  WHERE g.manager_id = v_caller
    AND g.provider_key = v_provider_key
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'OEM_DEVICE_GRANT_NOT_FOUND';
  END IF;

  IF v_grant.grant_status IS DISTINCT FROM 'granted' THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'OEM_DEVICE_GRANT_NOT_GRANTED',
      DETAIL = pg_catalog.format('provider_key=%s, grant_status=%s', v_provider_key, v_grant.grant_status);
  END IF;

  UPDATE public.oem_device_grants
  SET is_enabled = p_enabled,
      updated_at = pg_catalog.now()
  WHERE id = v_grant.id
    AND manager_id = v_caller
    AND provider_key = v_provider_key
    AND grant_status = 'granted'
  RETURNING * INTO v_grant;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'OEM_DEVICE_GRANT_STATE_CHANGED';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'provider_key', v_grant.provider_key,
    'grant_status', v_grant.grant_status,
    'is_enabled', v_grant.is_enabled,
    'metric_whitelist', v_grant.metric_whitelist,
    'updated_at', v_grant.updated_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.set_my_device_grant_enabled(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_my_device_grant_enabled(text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_my_device_grant_enabled(text, boolean) TO authenticated;

COMMENT ON FUNCTION public.set_my_device_grant_enabled(text, boolean) IS
  'Allows an authenticated manager to toggle only is_enabled on their own existing granted hardware entitlement. Does not insert rows and never modifies grant_status.';