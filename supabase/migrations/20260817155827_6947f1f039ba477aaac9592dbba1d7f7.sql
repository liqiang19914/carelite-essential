CREATE OR REPLACE FUNCTION public._test_cleanup_register(p_phone text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $function$
DECLARE
  v_uid uuid;
  v_ent uuid;
BEGIN
  SELECT id INTO v_uid FROM profiles WHERE phone = p_phone AND role = 'manager' ORDER BY created_at DESC LIMIT 1;
  IF v_uid IS NOT NULL THEN
    SELECT enterprise_id INTO v_ent FROM profiles WHERE id = v_uid;
    IF v_ent IS NOT NULL THEN
      DELETE FROM enterprise_role_permissions WHERE role_id IN (SELECT id FROM enterprise_roles WHERE enterprise_id = v_ent);
      DELETE FROM enterprise_roles WHERE enterprise_id = v_ent;
      UPDATE managers SET enterprise_id = NULL WHERE id = v_uid;
      UPDATE profiles SET enterprise_id = NULL WHERE id = v_uid;
      DELETE FROM enterprises WHERE id = v_ent;
    END IF;
    DELETE FROM managers WHERE id = v_uid;
    DELETE FROM profiles WHERE id = v_uid;
    DELETE FROM auth.users WHERE id = v_uid;
  END IF;
  DELETE FROM sms_verifications WHERE phone = p_phone;
END;
$function$;