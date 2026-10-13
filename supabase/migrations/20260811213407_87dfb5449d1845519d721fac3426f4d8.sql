CREATE INDEX IF NOT EXISTS idx_profiles_phone_normalized
  ON public.profiles (public.normalize_cn_phone(phone));