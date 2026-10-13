CREATE OR REPLACE FUNCTION public.create_measure_ticket(
  p_record_id uuid,
  p_provider_key text,
  p_oem_manager_id uuid DEFAULT NULL
)
RETURNS TABLE(ticket text, expires_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ticket text;
  v_expires timestamptz := now() + interval '10 minutes';
  v_oem uuid;
  v_cnt integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.owns_health_record(v_uid, p_record_id) THEN
    RAISE EXCEPTION 'record_not_owned';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.device_providers dp
    WHERE dp.provider_key = p_provider_key AND dp.status = 'active'
  ) THEN
    RAISE EXCEPTION 'provider_unavailable';
  END IF;

  -- 商户章只认服务端校验过的商户：声明的这家必须存在、是启用中的管理师、
  -- 且平台确实给它开通了这款秤（grant_status='granted'，与 get-oem-brand 同一口径；
  -- 不看 is_enabled —— 商户临时关掉开关不代表这条数据不是在它的应用里测的）。
  -- 校验不过宁可不盖章（只归平台可见），也不盖错章。
  IF p_oem_manager_id IS NOT NULL THEN
    SELECT pr.id INTO v_oem
    FROM public.profiles pr
    WHERE pr.id = p_oem_manager_id
      AND pr.role::text = 'manager'
      AND COALESCE(pr.is_disabled, false) = false
      AND EXISTS (
        SELECT 1 FROM public.oem_device_grants g
        WHERE g.manager_id = pr.id
          AND g.provider_key = p_provider_key
          AND g.grant_status = 'granted'
      );
  ELSE
    -- 没带商户身份（老小程序包、或从平台入口进来）时：如果这个人只归属一家开通了这款秤的商户，
    -- 归属唯一就不会盖错；有多家则留空交平台核对。
    SELECT count(*), min(cr.manager_id) INTO v_cnt, v_oem
    FROM public.client_relations cr
    WHERE cr.client_id = v_uid
      AND cr.status = 'active'
      AND EXISTS (
        SELECT 1 FROM public.oem_device_grants g
        WHERE g.manager_id = cr.manager_id
          AND g.provider_key = p_provider_key
          AND g.grant_status = 'granted'
      );
    IF v_cnt <> 1 THEN
      v_oem := NULL;
    END IF;
  END IF;

  -- 在商户应用内测量即视为这家的客户：自动建立归属，且不解除他与其他商户的归属。
  -- 建不上（比如商户客户数到套餐上限）也绝不能挡住测量——商户端靠商户章仍然看得到这条数据。
  IF v_oem IS NOT NULL THEN
    BEGIN
      INSERT INTO public.client_relations (manager_id, client_id, status, notes)
      VALUES (v_oem, v_uid, 'active', '在商户小程序内测量自动建立')
      ON CONFLICT (manager_id, client_id) DO UPDATE
        SET status = 'active'
        WHERE public.client_relations.status <> 'active';
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  DELETE FROM public.measure_tickets mt
  WHERE mt.expires_at < now() - interval '7 days';

  v_ticket := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO public.measure_tickets (ticket, user_id, record_id, provider_key, expires_at, oem_manager_id)
  VALUES (v_ticket, v_uid, p_record_id, p_provider_key, v_expires, v_oem);

  RETURN QUERY SELECT v_ticket, v_expires;
END;
$function$;