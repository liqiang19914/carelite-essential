CREATE OR REPLACE FUNCTION public._fix_enterprise_rebuild()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $function$
DECLARE
  v_owner uuid;
  v_ent uuid;
  v_name text;
  v_super uuid;
  v_cnt int := 0;
  v_expected int;
  v_test_ent uuid := '6cbfe929-be4c-457c-868f-8668be5fdabf';
  v_test_owner uuid := '31685996-3218-4b31-bd05-7128beee7426';
  v_ym uuid := '5424dfb1-f528-436c-bd75-2028e3c2e286';
  v_example uuid := '00000000-0000-0000-0000-00000000a001';
BEGIN
  SELECT count(*) INTO v_expected FROM public.profiles WHERE role = 'manager';
  IF v_expected <> 45 THEN
    RAISE EXCEPTION '前置断言失败：预期 45 个 manager，实际 %', v_expected;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.enterprises WHERE id = v_test_ent AND owner_profile_id = v_test_owner) THEN
    RAISE EXCEPTION '前置断言失败：测试企业老板不匹配';
  END IF;

  FOR v_owner IN
    SELECT p.id FROM public.profiles p
    WHERE p.role = 'manager' AND p.id <> v_test_owner
    ORDER BY p.created_at NULLS LAST, p.id
  LOOP
    SELECT left(COALESCE(NULLIF(trim(m.business_name), ''), NULLIF(trim(p.nickname), ''), '默认企业'), 100)
      INTO v_name
    FROM public.profiles p
    LEFT JOIN public.managers m ON m.id = p.id
    WHERE p.id = v_owner;

    INSERT INTO public.enterprises (name, owner_profile_id, created_by)
    VALUES (v_name, v_owner, NULL)
    RETURNING id INTO v_ent;

    SELECT id INTO v_super FROM public.enterprise_roles WHERE enterprise_id = v_ent AND code = 'super_admin';
    IF v_super IS NULL THEN
      RAISE EXCEPTION '企业 % 缺少超级管理员角色', v_ent;
    END IF;

    UPDATE public.profiles
       SET enterprise_id = v_ent, enterprise_role_id = v_super, parent_manager_id = NULL, sub_role = ''
     WHERE id = v_owner;
    UPDATE public.managers SET enterprise_id = v_ent WHERE id = v_owner;
    UPDATE public.health_manager_agents SET enterprise_id = v_ent WHERE manager_id = v_owner;
    UPDATE public.manager_knowledge_documents SET enterprise_id = v_ent WHERE manager_id = v_owner;

    v_cnt := v_cnt + 1;
  END LOOP;

  IF v_cnt <> 44 THEN
    RAISE EXCEPTION '断言失败：预期重建 44 家企业，实际 %', v_cnt;
  END IF;

  ALTER TABLE public.manager_content_album_pages DROP CONSTRAINT manager_content_album_pages_parent_fkey;
  ALTER TABLE public.manager_content_items DISABLE TRIGGER manager_content_items_before_write_trg;
  ALTER TABLE public.manager_content_album_pages DISABLE TRIGGER manager_content_album_pages_before_write_trg;
  ALTER TABLE public.manager_content_album_pages DISABLE TRIGGER manager_content_album_pages_reset_moderation_trg;

  UPDATE public.manager_content_album_pages SET root_manager_id = v_ym WHERE root_manager_id = v_test_owner;
  UPDATE public.manager_content_items SET root_manager_id = v_ym WHERE root_manager_id = v_test_owner;
  UPDATE public.manager_content_spaces SET root_manager_id = v_ym WHERE root_manager_id = v_test_owner;

  ALTER TABLE public.manager_content_album_pages ADD CONSTRAINT manager_content_album_pages_parent_fkey
    FOREIGN KEY (content_id, root_manager_id) REFERENCES public.manager_content_items(id, root_manager_id) ON DELETE CASCADE;
  ALTER TABLE public.manager_content_items ENABLE TRIGGER manager_content_items_before_write_trg;
  ALTER TABLE public.manager_content_album_pages ENABLE TRIGGER manager_content_album_pages_before_write_trg;
  ALTER TABLE public.manager_content_album_pages ENABLE TRIGGER manager_content_album_pages_reset_moderation_trg;

  UPDATE public.manager_courses SET manager_id = v_example
    WHERE id IN ('00000000-0000-0000-0000-00000000c001','00000000-0000-0000-0000-00000000c002','00000000-0000-0000-0000-00000000c003');

  RETURN '重建 ' || v_cnt || ' 家企业，内容与种子课程已纠偏';
END;
$function$;

REVOKE ALL ON FUNCTION public._fix_enterprise_rebuild() FROM PUBLIC;