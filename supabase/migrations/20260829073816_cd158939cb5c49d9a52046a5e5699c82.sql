-- 商品小程序码 scene 缩短：scene_code 为 10 字符 base64url 短码。
-- 生成小程序码时惰性补齐（UPDATE WHERE scene_code IS NULL），落地页按短码解析；
-- 旧 22 字符码仍走前端本地解码，不受影响。
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS scene_code varchar(10);

ALTER TABLE products
  ADD CONSTRAINT products_scene_code_format_check
  CHECK (scene_code IS NULL OR scene_code ~ '^[A-Za-z0-9_-]{10}$');

CREATE UNIQUE INDEX IF NOT EXISTS products_scene_code_unique_idx
  ON products (scene_code)
  WHERE scene_code IS NOT NULL;

-- 公开落地解析：按短码返回 active 商品 id；无效/未补齐/已下架一律 NULL。
-- SECURITY DEFINER + 固定 search_path，仅返回商品主键，无任何数据泄露面。
CREATE OR REPLACE FUNCTION public.resolve_product_scene_code(p_scene_code text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product_id uuid;
BEGIN
  IF p_scene_code IS NULL OR p_scene_code !~ '^[A-Za-z0-9_-]{10}$' THEN
    RETURN NULL;
  END IF;
  SELECT p.id
    INTO v_product_id
    FROM public.products p
   WHERE p.scene_code = p_scene_code
     AND p.status = 'active'
   LIMIT 1;
  RETURN v_product_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_product_scene_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_product_scene_code(text) TO anon, authenticated;