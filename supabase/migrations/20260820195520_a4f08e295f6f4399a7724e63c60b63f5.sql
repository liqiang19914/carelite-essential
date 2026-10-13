-- 店铺装修作用域扩展：新增 reputation（达人口碑页）。
-- 与 20260818033134 那次加 content/shop 同一套路：
--   1) 两列默认值补 reputation 键
--   2) validate_shop_pages 读时归一化补 reputation（缺键一律补空数组）——这是兼容底线
--   3) 用新校验函数回填存量 draft_pages/published_pages，保留旧四页内容、补 reputation:[]，不动 published_at
-- 读时归一化兜底：即便回填漏跑，旧 JSON 缺 reputation 也会被归一成空数组，不会报错。

ALTER TABLE public.merchant_shop_configs
  ALTER COLUMN draft_pages SET DEFAULT '{"home":[],"school":[],"content":[],"shop":[],"reputation":[]}'::jsonb,
  ALTER COLUMN published_pages SET DEFAULT '{"home":[],"school":[],"content":[],"shop":[],"reputation":[]}'::jsonb;

COMMENT ON COLUMN public.merchant_shop_configs.draft_pages IS
  '草稿页面 {home:[{type,data}], school:[...], content:[...], shop:[...], reputation:[...]}，数组顺序即渲染顺序；home=健康管理师页 school=学堂页(兼容) content=内容中心 shop=商城 reputation=达人口碑页';

CREATE OR REPLACE FUNCTION public.validate_shop_pages(p_pages jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
BEGIN
  IF p_pages IS NULL OR jsonb_typeof(p_pages) <> 'object' THEN
    RAISE EXCEPTION '装修数据结构不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object(
    'home', public.normalize_shop_module_list(COALESCE(p_pages->'home', '[]'::jsonb)),
    'school', public.normalize_shop_module_list(COALESCE(p_pages->'school', '[]'::jsonb)),
    'content', public.normalize_shop_module_list(COALESCE(p_pages->'content', '[]'::jsonb)),
    'shop', public.normalize_shop_module_list(COALESCE(p_pages->'shop', '[]'::jsonb)),
    'reputation', public.normalize_shop_module_list(COALESCE(p_pages->'reputation', '[]'::jsonb))
  );
END;
$function$;

-- 物理回填存量配置：过一遍新校验函数，旧四页内容原样保留，补上 reputation:[]。
-- 只补空数组、不写默认模块（默认模块由前端构造），不改变 published_at。
UPDATE public.merchant_shop_configs
   SET draft_pages = public.validate_shop_pages(COALESCE(draft_pages, '{}'::jsonb)),
       published_pages = public.validate_shop_pages(COALESCE(published_pages, '{}'::jsonb));