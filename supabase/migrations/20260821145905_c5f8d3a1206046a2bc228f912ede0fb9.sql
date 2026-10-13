-- 存量解除的「恰 1 行」断言补丁（幂等）：
-- 目标行已 inactive → 直接通过；仍 active 且根不一致断言成立 → 更新并强制验证恰影响 1 行；否则报错。
DO $function$
DECLARE
  v_status text;
  v_rows int := 0;
BEGIN
  SELECT status INTO v_status
  FROM public.client_relations
  WHERE id = 'e68fb9d0-5698-4fea-aec6-c8ce50faec56';

  IF v_status IS NULL THEN
    RAISE EXCEPTION '目标绑定关系不存在，请人工核对';
  ELSIF v_status <> 'inactive' THEN
    UPDATE public.client_relations cr
       SET status = 'inactive', updated_at = NOW()
     WHERE cr.id = 'e68fb9d0-5698-4fea-aec6-c8ce50faec56'
       AND cr.status = 'active'
       AND EXISTS (
         SELECT 1
         FROM public.shop_members sm
         WHERE sm.client_id = cr.client_id
           AND sm.created_at = (
             SELECT MAX(sm2.created_at)
             FROM public.shop_members sm2
             WHERE sm2.client_id = cr.client_id
           )
           AND sm.root_manager_id IS DISTINCT FROM (
             SELECT COALESCE(p.parent_manager_id, p.id)
             FROM public.profiles p
             WHERE p.id = cr.manager_id
           )
       );
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
      RAISE EXCEPTION '存量解除断言未命中：期望恰 1 行，实际 %', v_rows;
    END IF;
  END IF;
END;
$function$;