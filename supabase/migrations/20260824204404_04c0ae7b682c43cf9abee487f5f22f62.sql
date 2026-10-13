-- 底部菜单跳转目标全量化：图标白名单 16 → 30 键，内置页目标 7 → 27 键（账户页全集，实名认证除外）。
-- 与前端 SHELL_NAV_ICONS / SHELL_BUILTIN_TARGETS、get-oem-shell-config EF 白名单同口径。
CREATE OR REPLACE FUNCTION public.validate_shell_navigation(p_nav jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_item jsonb;
  v_id text;
  v_label text;
  v_icon text;
  v_type text;
  v_value text;
  v_ids text[] := '{}';
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_nav IS NULL OR jsonb_typeof(p_nav) <> 'array' THEN
    RAISE EXCEPTION '底部菜单数据格式不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_nav) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_array_length(p_nav) < 3 OR jsonb_array_length(p_nav) > 5 THEN
    RAISE EXCEPTION '底部菜单需要 3~5 个，请调整后重试' USING ERRCODE = '22023';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_nav)
  LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION '存在无效的菜单项，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_id := NULLIF(btrim(v_item->>'id'), '');
    IF v_id IS NULL OR char_length(v_id) > 40 THEN
      RAISE EXCEPTION '存在缺少编号的菜单项，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    IF v_id = ANY(v_ids) THEN
      RAISE EXCEPTION '菜单项编号重复，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_ids := v_ids || v_id;
    v_label := NULLIF(btrim(v_item->>'label'), '');
    IF v_label IS NULL OR char_length(v_label) > 8 THEN
      RAISE EXCEPTION '菜单名称需要 1~8 个字，请检查后重试' USING ERRCODE = '22023';
    END IF;
    v_icon := v_item->>'icon';
    IF v_icon IS NULL OR v_icon <> ALL(ARRAY['home','message','heart','handshake','scale','store','book','article','course','image','star','user','folder','headset','link','compass','coins','map','bell','lock','help','feedback','qrcode','shield','layout','clipboard','pen','megaphone','newspaper','report']) THEN
      RAISE EXCEPTION '存在不支持的菜单图标，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_type := v_item->>'targetType';
    v_value := v_item->>'targetValue';
    IF v_type = 'builtin' THEN
      IF v_value IS NULL OR v_value <> ALL(ARRAY['home','manager','me','chat','weighing','shop','content','records','reports','my_manager','reputation','points','favorites','orders','addresses','store_orders','frequent_store','store_application','store_admin','promotion_center','promotion_qr','profile','notifications','privacy','help','feedback','agreement']) THEN
        RAISE EXCEPTION '存在不支持的菜单跳转页面，请刷新后重试' USING ERRCODE = '22023';
      END IF;
    ELSIF v_type = 'custom_page' THEN
      IF v_value IS NULL OR v_value !~ '^[a-z0-9][a-z0-9_-]{0,39}$' THEN
        RAISE EXCEPTION '菜单指向的自定义页面不正确，请刷新后重试' USING ERRCODE = '22023';
      END IF;
    ELSIF v_type = 'custom' THEN
      IF v_value IS NULL OR char_length(v_value) > 500
         OR (v_value !~ '^https://' AND v_value !~ '^/') THEN
        RAISE EXCEPTION '自定义链接需要以 https:// 或 / 开头，请检查后重试' USING ERRCODE = '22023';
      END IF;
    ELSE
      RAISE EXCEPTION '存在不支持的菜单跳转类型，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_out := v_out || jsonb_build_object('id', v_id, 'label', v_label, 'icon', v_icon, 'targetType', v_type, 'targetValue', v_value);
  END LOOP;
  RETURN v_out;
END;
$function$;