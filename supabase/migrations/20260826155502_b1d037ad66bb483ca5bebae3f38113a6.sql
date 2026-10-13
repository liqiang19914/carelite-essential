-- 审查修复 1：编辑群时 webhook 留空=保持原值（先取存量再校验）
CREATE OR REPLACE FUNCTION public.save_merchant_wecom_group(
  p_name text,
  p_webhook_url text,
  p_enabled boolean DEFAULT true,
  p_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_webhook text;
  v_existing text;
  v_id uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;

  v_name := btrim(COALESCE(p_name, ''));
  IF char_length(v_name) < 1 OR char_length(v_name) > 50 THEN
    RAISE EXCEPTION '群名称需在 1-50 个字符之间' USING ERRCODE = 'P0002';
  END IF;

  v_webhook := btrim(COALESCE(p_webhook_url, ''));
  IF p_id IS NOT NULL THEN
    SELECT g.webhook_url INTO v_existing
      FROM public.merchant_wecom_groups g
     WHERE g.id = p_id AND g.root_manager_id = v_root;
    IF v_existing IS NULL THEN
      RAISE EXCEPTION '该群不存在或无权操作' USING ERRCODE = 'P0002';
    END IF;
    v_webhook := COALESCE(NULLIF(v_webhook, ''), v_existing);
  END IF;

  IF v_webhook !~ '^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9\-_]{16,128}$' THEN
    RAISE EXCEPTION '请粘贴企业微信群机器人的完整 Webhook 地址（以 https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key= 开头）' USING ERRCODE = 'P0002';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.merchant_wecom_groups (root_manager_id, name, webhook_url, enabled, public_token)
    VALUES (v_root, v_name, v_webhook, COALESCE(p_enabled, true), gen_random_uuid()::text)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.merchant_wecom_groups
       SET name = v_name,
           webhook_url = v_webhook,
           enabled = COALESCE(p_enabled, true),
           consecutive_failures = 0,
           disabled_reason = NULL,
           updated_at = now()
     WHERE id = p_id AND root_manager_id = v_root
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION '该群不存在或无权操作' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id, 'name', v_name);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_group(text, text, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_group(text, text, boolean, uuid) TO authenticated;

-- 审查修复 2：定时推送开启时，小贴士不得少于 7 条（防静默停摆）
CREATE OR REPLACE FUNCTION public.save_merchant_wecom_tips(p_tips jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_arr jsonb;
  v_item record;
  v_count int := 0;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;

  v_arr := COALESCE(p_tips, '[]'::jsonb);
  IF jsonb_typeof(v_arr) <> 'array' THEN
    RAISE EXCEPTION '小贴士格式不正确' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_array_length(v_arr) > 30 THEN
    RAISE EXCEPTION '健康小贴士最多 30 条' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_array_length(v_arr) < 7 AND EXISTS (
    SELECT 1 FROM public.merchant_wecom_settings
     WHERE root_manager_id = v_root AND scheduled_enabled = true
  ) THEN
    RAISE EXCEPTION '定时推送已开启，健康小贴士至少保留 7 条；如需删除请先关闭定时推送' USING ERRCODE = 'P0002';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_arr)
  LOOP
    IF char_length(btrim(COALESCE(v_item.value->>'content', ''))) NOT BETWEEN 1 AND 600 THEN
      RAISE EXCEPTION '每条小贴士需在 1-600 字之间' USING ERRCODE = 'P0002';
    END IF;
  END LOOP;

  DELETE FROM public.merchant_wecom_tips WHERE root_manager_id = v_root;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_arr) WITH ORDINALITY AS t(value, ord)
  LOOP
    INSERT INTO public.merchant_wecom_tips (root_manager_id, content, sort_order)
    VALUES (v_root, btrim(COALESCE(v_item.value->>'content', '')), v_item.ord);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('count', v_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_tips(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_tips(jsonb) TO authenticated;