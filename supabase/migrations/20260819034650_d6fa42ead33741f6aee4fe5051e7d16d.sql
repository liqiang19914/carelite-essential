-- 清掉旧的 11 参数版本，只保留带 description_doc 的 12 参数版本
DROP FUNCTION IF EXISTS public.manager_create_product(
  text, text, text, text, jsonb, jsonb, text, text[], text, integer, text
);