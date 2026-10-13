-- auth 侧按号查人：同时接受带 86 与裸 11 位两种数字指纹，兼容历史存量
CREATE OR REPLACE FUNCTION public.find_auth_user_by_phone(p_phone text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $function$
  SELECT jsonb_build_object(
    'id', id::text,
    'phone', phone,
    'user_metadata', raw_user_meta_data
  )
  FROM auth.users
  WHERE phone IS NOT NULL
    AND regexp_replace(phone, '[^0-9]', '', 'g') IN (
      public.auth_phone_digits(p_phone),
      regexp_replace(public.normalize_phone_identity(p_phone), '[^0-9]', '', 'g')
    )
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.admin_find_auth_user_by_phones(p_phones text[])
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT u.id
  FROM auth.users u
  WHERE u.phone IS NOT NULL
    AND regexp_replace(u.phone, '[^0-9]', '', 'g') IN (
      SELECT c.candidate
      FROM unnest(p_phones) AS x
      CROSS JOIN LATERAL (
        VALUES
          (public.auth_phone_digits(x)),
          (regexp_replace(public.normalize_phone_identity(x), '[^0-9]', '', 'g'))
      ) AS c(candidate)
    )
  ORDER BY u.created_at
  LIMIT 1;
$function$;

-- 收回按号查人接口的普通用户调用权，仅保留服务端角色（防手机号枚举）
REVOKE ALL ON FUNCTION public.find_profile_id_by_phone(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.find_auth_user_by_phone(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.find_profile_id_by_phone(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.find_auth_user_by_phone(text) TO service_role;