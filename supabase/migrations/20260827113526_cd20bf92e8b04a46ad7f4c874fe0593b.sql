CREATE OR REPLACE FUNCTION public.assign_profile_member_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  candidate text;
  attempts int := 0;
BEGIN
  IF NEW.role IS DISTINCT FROM 'user' THEN
    RETURN NEW;
  END IF;
  IF NEW.member_code IS NOT NULL THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('profile_member_code_assign'));
  LOOP
    attempts := attempts + 1;
    IF attempts > 20 THEN
      RAISE EXCEPTION '会员识别码分配失败，请重试';
    END IF;
    candidate := lpad((floor(random() * 900000)::int + 100000)::text, 6, '0');
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE member_code = candidate) THEN
      NEW.member_code := candidate;
      EXIT;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$function$;