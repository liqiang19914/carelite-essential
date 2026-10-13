UPDATE public.profiles
SET phone = public.normalize_cn_phone(phone)
WHERE phone IS NOT NULL
  AND public.normalize_cn_phone(phone) <> ''
  AND phone IS DISTINCT FROM public.normalize_cn_phone(phone);