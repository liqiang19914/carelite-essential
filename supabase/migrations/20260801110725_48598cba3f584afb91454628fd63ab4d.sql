-- 修票据签发：RETURNS TABLE 的 expires_at 出参与 measure_tickets.expires_at 列同名，
-- 清理过期票据那句 DELETE 里的裸 expires_at 被 PL/pgSQL 判为二义（42702），
-- 导致整个签发 RPC 直接报错、真机测量根本发不出票。给表加别名后引用即可消歧。
CREATE OR REPLACE FUNCTION public.create_measure_ticket(p_record_id uuid, p_provider_key text)
RETURNS TABLE(ticket text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ticket text;
  v_expires timestamptz := now() + interval '10 minutes';
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

  DELETE FROM public.measure_tickets mt
  WHERE mt.expires_at < now() - interval '7 days';

  v_ticket := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO public.measure_tickets (ticket, user_id, record_id, provider_key, expires_at)
  VALUES (v_ticket, v_uid, p_record_id, p_provider_key, v_expires);

  RETURN QUERY SELECT v_ticket, v_expires;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_measure_ticket(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_measure_ticket(uuid, text) TO authenticated;