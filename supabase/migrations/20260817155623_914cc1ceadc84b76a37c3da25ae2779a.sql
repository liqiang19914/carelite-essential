CREATE OR REPLACE FUNCTION public._test_seed_sms(p_phone text, p_code text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $function$
BEGIN
  DELETE FROM sms_verifications WHERE phone = p_phone;
  INSERT INTO sms_verifications (phone, code, expires_at) VALUES (p_phone, p_code, now() + interval '10 minutes');
END;
$function$;