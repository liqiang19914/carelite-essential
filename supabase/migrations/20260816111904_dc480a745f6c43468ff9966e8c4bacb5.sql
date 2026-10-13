CREATE OR REPLACE FUNCTION public._is_public_system_setting(p_key text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT p_key IN (
    'miniapp_brand_name',
    'miniapp_brand_logo_url',
    'miniapp_brand_primary_color',
    'miniapp_ai_agent_name',
    'miniapp_brand_full_name',
    'miniapp_privacy_policy_url',
    'miniapp_terms_url',
    'miniapp_support_contact',
    'miniapp_shop_banner',
    'domain_user',
    'display_live_enabled',
    'display_private_butler_enabled',
    'display_verification_enabled'
  );
$function$