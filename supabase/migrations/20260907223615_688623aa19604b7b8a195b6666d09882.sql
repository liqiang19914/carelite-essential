-- 458 游客「问问AI」落地改对话页形态：
-- 平台主程序（小凯同学）根直达平台对话页 /chat；其余商户直达 /m/{短码}/chat（公开对话页）。
-- 接待智能体解析链（merchant_wecom_settings.agent_manager_id -> managers.short_code）语义不变，仅落地后缀与平台根短路变更。
CREATE OR REPLACE FUNCTION public.resolve_merchant_guest_chat_path(p_root uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT CASE
    -- 平台主程序（小凯同学）根：游客问问AI落在平台对话页，不进带名片头部的公开问答页
    WHEN p_root = 'a6f5c22f-33ec-411f-ad26-3777ebbb534e'::uuid THEN '/chat'
    ELSE (
      SELECT '/m/' || COALESCE(NULLIF(btrim(m.short_code), ''), m.id::text) || '/chat'
      FROM public.merchant_wecom_settings s
      JOIN public.managers m ON m.id = s.agent_manager_id
      WHERE s.root_manager_id = p_root
        AND s.agent_manager_id IS NOT NULL
      LIMIT 1
    )
  END
$function$;

REVOKE EXECUTE ON FUNCTION public.resolve_merchant_guest_chat_path(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_merchant_guest_chat_path(uuid) TO service_role;