-- ============ 国际号码规范化：大陆裸 11 位 / 国际 E.164 / 非法 '' ============
CREATE OR REPLACE FUNCTION public.normalize_phone_identity(raw text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $function$
  SELECT CASE
    WHEN d ~ '^1[3-9][0-9]{9}$' THEN d
    WHEN d ~ '^852[0-9]{8}$' THEN '+852' || substr(d, 4)
    WHEN d ~ '^853[0-9]{8}$' THEN '+853' || substr(d, 4)
    WHEN d ~ '^886[0-9]{8,9}$' THEN '+886' || substr(d, 4)
    ELSE ''
  END
  FROM (
    SELECT regexp_replace(ltrim(regexp_replace(coalesce(raw, ''), '[^0-9]', '', 'g'), '0'), '^(86)+', '') AS d
  ) t;
$function$;

-- 规范号 → auth.users 写入口径（带 + 的 E.164；GoTrue 入库剥 +，比对一律按数字指纹）
CREATE OR REPLACE FUNCTION public.phone_to_e164(p_identity text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $function$
  SELECT CASE
    WHEN p_identity ~ '^1[3-9][0-9]{9}$' THEN '+86' || p_identity
    WHEN p_identity ~ '^\+[1-9][0-9]{6,14}$' THEN p_identity
    ELSE ''
  END;
$function$;

-- 任意输入 → auth.users.phone 的数字指纹（与入库剥 + 的口径一致）
CREATE OR REPLACE FUNCTION public.auth_phone_digits(p_phone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $function$
  SELECT regexp_replace(public.phone_to_e164(public.normalize_phone_identity(p_phone)), '[^0-9]', '', 'g');
$function$;

-- profiles 手机号写入触发器：国际号写 E.164，非法值置 NULL
CREATE OR REPLACE FUNCTION public.normalize_profile_phone()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
DECLARE
  v_norm text;
BEGIN
  IF new.phone IS NULL OR btrim(new.phone) = '' THEN
    RETURN new;
  END IF;
  v_norm := public.normalize_phone_identity(new.phone);
  IF v_norm <> '' THEN
    new.phone := v_norm;
  ELSE
    new.phone := NULL;
  END IF;
  RETURN new;
END;
$function$;

-- 按号认人：两侧统一按国际口径规范化，空输入返回空结果
CREATE OR REPLACE FUNCTION public.find_profile_id_by_phone(p_phone text, p_role text DEFAULT 'user')
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $function$
  SELECT p.id
  FROM public.profiles p
  WHERE public.normalize_phone_identity(p_phone) <> ''
    AND public.normalize_phone_identity(p.phone) = public.normalize_phone_identity(p_phone)
    AND (p_role IS NULL OR p.role::text = p_role)
  ORDER BY
    (EXISTS (SELECT 1 FROM public.health_records hr WHERE hr.user_id = p.id)) DESC,
    p.created_at ASC
  LIMIT 1;
$function$;

-- auth 侧按号查人：数字指纹比对，兼容带/不带 + 的历史存量
CREATE OR REPLACE FUNCTION public.find_auth_user_by_phone(p_phone text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $function$
  SELECT jsonb_build_object(
    'id', id::text,
    'phone', phone,
    'user_metadata', raw_user_meta_data
  )
  FROM auth.users
  WHERE phone IS NOT NULL
    AND regexp_replace(phone, '[^0-9]', '', 'g') = public.auth_phone_digits(p_phone)
  LIMIT 1;
$function$;

-- 批量查号：数字指纹比对，兼容历史存量
CREATE OR REPLACE FUNCTION public.admin_find_auth_user_by_phones(p_phones text[])
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT u.id
  FROM auth.users u
  WHERE u.phone IS NOT NULL
    AND regexp_replace(u.phone, '[^0-9]', '', 'g') IN (
      SELECT public.auth_phone_digits(x)
      FROM unnest(p_phones) AS x
    )
  ORDER BY u.created_at
  LIMIT 1;
$function$;

-- 表达式索引随新规范化函数重建（大陆号查询路径同样命中）
DROP INDEX IF EXISTS public.idx_profiles_phone_normalized;
CREATE INDEX IF NOT EXISTS idx_profiles_phone_normalized
  ON public.profiles (public.normalize_phone_identity(phone));