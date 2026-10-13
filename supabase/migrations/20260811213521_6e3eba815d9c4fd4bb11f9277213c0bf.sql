REVOKE EXECUTE ON FUNCTION public.find_profile_id_by_phone(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.find_profile_id_by_phone(text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.create_manager_client(p_nickname text, p_phone text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  v_manager_id uuid := auth.uid();
  v_client_id uuid;
  v_existing_relation uuid;
  v_existing_status text;
  v_raw text := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_phone text;
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF v_raw IS NOT NULL THEN
    v_phone := NULLIF(public.normalize_cn_phone(v_raw), '');
    IF v_phone IS NULL THEN
      RAISE EXCEPTION '手机号填写有误，请填 11 位中国大陆手机号' USING ERRCODE = '22023';
    END IF;
    -- 按数字认人：+86 / 86 / 裸号视为同一个人。原实现是单一字符串等值匹配，
    -- 格式差一个加号就当成新人另建档案，这正是重复档案的来源。
    v_client_id := public.find_profile_id_by_phone(v_phone, 'user');
  END IF;

  IF v_client_id IS NOT NULL THEN
    SELECT id, status INTO v_existing_relation, v_existing_status
    FROM public.client_relations
    WHERE manager_id = v_manager_id AND client_id = v_client_id;

    IF v_existing_relation IS NOT NULL THEN
      IF v_existing_status = 'active' THEN
        RAISE EXCEPTION '该客户已存在' USING ERRCODE = '23505';
      END IF;
      UPDATE public.client_relations
      SET status = 'active',
          notes = COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), notes),
          last_contact_at = now()
      WHERE id = v_existing_relation;
      RETURN v_client_id;
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
$$;