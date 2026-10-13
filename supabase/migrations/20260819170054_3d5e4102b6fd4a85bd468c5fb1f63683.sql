-- 修复商品列表「提交审核」死锁（Feature 195）
-- 1. 存量商户 pending_review 商品直接置为 active（商户当初提交就是想上架）
-- 2. 平台铃铛 pending_products 只统计平台商品（商户商品不再走审核）

-- 1. 存量商户待审核商品直接上架
UPDATE products
SET status = 'active', updated_at = clock_timestamp()
WHERE source_type = 'manager' AND status = 'pending_review';

-- 2. 铃铛计数：pending_products 只统计平台商品
CREATE OR REPLACE FUNCTION public.get_admin_pending_counts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅管理员可查看' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'pending_products',
      (SELECT count(*) FROM public.products WHERE source_type = 'platform' AND status = 'pending_review'),
    'pending_courses',
      (SELECT count(*) FROM public.manager_courses WHERE review_status = 'pending_review'),
    'pending_content',
      (SELECT count(*) FROM public.manager_content_items
        WHERE is_published = true AND moderation_status IN ('manual_review','flagged','pending'))
  );
END;
$function$;