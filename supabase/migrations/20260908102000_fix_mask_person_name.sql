-- 修复订单/评价列表昵称脱敏显示成"李○○○○○…"像乱码的问题：
-- 原实现按原名长度用"○"填充，长微信昵称会渲染成一长串圆圈，且泄露昵称长度。
-- 改为固定「首字符 + **」（与手机号 150***150 的星号风格一致）。
CREATE OR REPLACE FUNCTION public._mask_person_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN COALESCE(btrim(p_name), '') = '' THEN ''
    WHEN char_length(btrim(p_name)) = 1 THEN btrim(p_name)
    ELSE left(btrim(p_name), 1) || '**'
  END;
$$;

REVOKE ALL ON FUNCTION public._mask_person_name(text) FROM PUBLIC;
