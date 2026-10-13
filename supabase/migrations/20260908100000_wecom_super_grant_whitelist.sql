-- 企微超级助手补丁：模块状态读取 RPC + AI 建议列表增强。
--
-- 背景：平台既有授权 RPC（admin_set_merchant_module_grant /
-- get_my_merchant_module_state）属主为平台迁移角色，EF 直连角色无权
-- CREATE OR REPLACE 它们（must be owner）。因此不替换既有函数，而是创建
-- 模块自有的状态读取 RPC get_wecom_super_module_state()（EF 直连角色所有）。
-- 前端菜单闸门、平台 EF 一律走本函数/EF admin.grant.set，不依赖既有 RPC 白名单。
--
-- 语义：open = 平台已授予(grant_status='granted') 且 is_enabled。
-- 该模块没有商户自助开关：平台通过 EF admin.grant.set 授予时 is_enabled 置 true。
--
-- 修订（经一次性迁移 EF 3 上线）：
-- - 风险确认列名为 risk_ack_at（初版误写 risk_ack，会导致菜单 RPC 整体报错）；
-- - list_wecom_super_ai_suggestions 增加 p_status='queued' 伪状态
--   （approved + auto_sent，即已入队未发完）。

CREATE OR REPLACE FUNCTION public.get_wecom_super_module_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root    uuid;
  v_granted boolean := false;
  v_enabled boolean := false;
  v_ack     boolean := false;
BEGIN
  v_root := public._my_root_manager_id();
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(g.grant_status = 'granted', false), COALESCE(g.is_enabled, false)
    INTO v_granted, v_enabled
    FROM public.merchant_module_grants g
   WHERE g.manager_id = v_root
     AND g.module_key = 'wecom_super_assistant';

  SELECT (c.risk_ack_at IS NOT NULL)
    INTO v_ack
    FROM public.wecom_super_merchant_config c
   WHERE c.root_manager_id = v_root;

  RETURN jsonb_build_object(
    'granted', v_granted,
    'enabled', v_enabled,
    'riskAcked', COALESCE(v_ack, false),
    'open', v_granted AND v_enabled
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_wecom_super_module_state() TO authenticated;

CREATE OR REPLACE FUNCTION public.list_wecom_super_ai_suggestions(
  p_status text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_ai_suggestions s
  WHERE s.root_manager_id = v_root
    AND (
      v_status IS NULL
      OR s.status = v_status
      OR (v_status = 'queued' AND s.status IN ('approved', 'auto_sent'))
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT s.id, s.client_id AS "clientId", s.client_name AS "clientName",
           s.target_id AS "targetId", s.device_guid AS "deviceGuid",
           s.suggested_content AS "suggestedContent", s.context,
           s.status, s.task_id AS "taskId", s.last_error AS "lastError",
           s.handled_at AS "handledAt", s.created_at AS "createdAt"
    FROM public.wecom_super_ai_suggestions s
    WHERE s.root_manager_id = v_root
      AND (
        v_status IS NULL
        OR s.status = v_status
        OR (v_status = 'queued' AND s.status IN ('approved', 'auto_sent'))
      )
    ORDER BY s.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_ai_suggestions(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_ai_suggestions(text, int, int) TO authenticated;
