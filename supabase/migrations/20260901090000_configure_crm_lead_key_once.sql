-- One-time, tightly scoped setter used to provision the HMS website CRM key
-- without ever placing the secret in frontend or migration source.
CREATE OR REPLACE FUNCTION public._configure_crm_lead_api_key_once(p_value text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS DISTINCT FROM '5424dfb1-f528-436c-bd75-2028e3c2e286'::uuid THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  IF p_value IS NULL OR length(btrim(p_value)) < 20 OR btrim(p_value) NOT LIKE 'lk\_%' ESCAPE '\\' THEN
    RAISE EXCEPTION 'invalid CRM lead API key';
  END IF;

  INSERT INTO public.system_settings (key, value, description, updated_at)
  VALUES (
    'crm_lead_api_key',
    btrim(p_value),
    '小凯同学HMS官网留资转发密钥（仅 service_role 可读）',
    now()
  )
  ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value,
      description = EXCLUDED.description,
      updated_at = now();

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public._configure_crm_lead_api_key_once(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._configure_crm_lead_api_key_once(text) TO authenticated;

