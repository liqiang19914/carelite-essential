CREATE OR REPLACE FUNCTION public.normalize_profile_phone()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_norm text;
BEGIN
  IF new.phone IS NULL OR btrim(new.phone) = '' THEN
    RETURN new;
  END IF;
  v_norm := public.normalize_cn_phone(new.phone);
  IF v_norm <> '' THEN
    new.phone := v_norm;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE TRIGGER trg_profiles_normalize_phone
BEFORE INSERT OR UPDATE OF phone ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.normalize_profile_phone();