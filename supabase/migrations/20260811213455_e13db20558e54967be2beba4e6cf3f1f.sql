CREATE OR REPLACE FUNCTION public.find_profile_id_by_phone(p_phone text, p_role text DEFAULT 'user')
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id
  FROM public.profiles p
  WHERE public.normalize_cn_phone(p_phone) <> ''
    AND public.normalize_cn_phone(p.phone) = public.normalize_cn_phone(p_phone)
    AND (p_role IS NULL OR p.role::text = p_role)
  ORDER BY
    (EXISTS (SELECT 1 FROM public.health_records hr WHERE hr.user_id = p.id)) DESC,
    p.created_at ASC
  LIMIT 1;
$$;