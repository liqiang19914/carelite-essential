-- ============================================================
-- create_manager_client：原子化"建档 + 建立归属关系"
-- 避免套餐客户数上限触发器拒绝时，已插入的客户 profiles 行变成
-- 无归属关系的孤儿记录（函数级事务：任一步失败则整体回滚）
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_manager_client(
  p_nickname text,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_client_id uuid;
  v_existing_relation uuid;
  v_phone text := NULLIF(btrim(COALESCE(p_phone, '')), '');
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF v_phone IS NOT NULL THEN
    SELECT id INTO v_client_id FROM public.profiles WHERE phone = v_phone;
  END IF;

  IF v_client_id IS NOT NULL THEN
    SELECT id INTO v_existing_relation FROM public.client_relations
      WHERE manager_id = v_manager_id AND client_id = v_client_id;
    IF v_existing_relation IS NOT NULL THEN
      RAISE EXCEPTION '该客户已存在' USING ERRCODE = '23505';
    END IF;
  ELSE
    v_client_id := gen_random_uuid();
    INSERT INTO public.profiles (id, phone, nickname, role)
    VALUES (v_client_id, COALESCE(v_phone, ''), COALESCE(NULLIF(btrim(p_nickname), ''), '未命名客户'), 'user');
  END IF;

  INSERT INTO public.client_relations (manager_id, client_id, status, notes)
  VALUES (v_manager_id, v_client_id, 'active', COALESCE(p_notes, ''));

  RETURN v_client_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_manager_client(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_manager_client(text, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.create_manager_client(text, text, text) FROM anon;
