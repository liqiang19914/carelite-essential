-- ============ 一、create_manager_client：复用关系 UPDATE 分支纳入 unique_violation 中文捕获 ============
CREATE OR REPLACE FUNCTION public.create_manager_client(p_nickname text, p_phone text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_root uuid;
  v_client_id uuid;
  v_existing_relation uuid;
  v_existing_status text;
  v_existing_manager uuid;
  v_raw text := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_phone text;
  v_customer_name text;
  v_owner_name text;
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager_id);

  IF v_raw IS NOT NULL THEN
    v_phone := NULLIF(public.normalize_cn_phone(v_raw), '');
    IF v_phone IS NULL THEN
      RAISE EXCEPTION '手机号填写有误，请填 11 位中国大陆手机号' USING ERRCODE = '22023';
    END IF;
    v_client_id := public.find_profile_id_by_phone(v_phone, 'user');

    IF v_client_id IS NOT NULL AND v_root IS NOT NULL THEN
      SELECT cr.id, cr.manager_id INTO v_existing_relation, v_existing_manager
      FROM public.client_relations cr
      WHERE cr.root_manager_id = v_root
        AND cr.client_phone_normalized = v_phone
        AND cr.status = 'active'
      LIMIT 1;

      IF v_existing_relation IS NOT NULL AND v_existing_manager <> v_manager_id THEN
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_existing_manager;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
      END IF;
    END IF;
  END IF;

  IF v_client_id IS NULL THEN
    v_client_id := gen_random_uuid();
    INSERT INTO public.profiles (id, phone, nickname, role)
    VALUES (v_client_id, COALESCE(v_phone, ''), COALESCE(NULLIF(btrim(p_nickname), ''), '未命名客户'), 'user');
  END IF;

  SELECT id, status INTO v_existing_relation, v_existing_status
  FROM public.client_relations
  WHERE manager_id = v_manager_id AND client_id = v_client_id;

  IF v_existing_relation IS NULL THEN
    SELECT id, status INTO v_existing_relation, v_existing_status
    FROM public.client_relations
    WHERE root_manager_id = v_root AND client_id = v_client_id AND status <> 'active'
    LIMIT 1;
  END IF;

  v_customer_name := COALESCE(NULLIF(btrim(p_nickname), ''), NULL);
  IF v_customer_name IS NULL THEN
    SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名客户') INTO v_customer_name
    FROM public.profiles WHERE id = v_client_id;
  END IF;

  IF v_existing_relation IS NOT NULL THEN
    BEGIN
      UPDATE public.client_relations
      SET status = 'active',
          manager_id = v_manager_id,
          root_manager_id = v_root,
          customer_name = COALESCE(v_customer_name, customer_name),
          client_phone_normalized = COALESCE(v_phone, client_phone_normalized),
          notes = COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), notes),
          last_contact_at = now(),
          updated_at = now()
      WHERE id = v_existing_relation;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_existing_manager
        FROM public.client_relations cr
        WHERE cr.root_manager_id = v_root AND cr.client_id = v_client_id AND cr.status = 'active'
          AND cr.manager_id <> v_manager_id
        LIMIT 1;
        IF v_existing_manager IS NULL THEN
          SELECT cr.manager_id INTO v_existing_manager
          FROM public.client_relations cr
          WHERE cr.root_manager_id = v_root AND cr.client_id = v_client_id AND cr.status = 'active'
          LIMIT 1;
        END IF;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_existing_manager;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;

    INSERT INTO public.client_assignment_history (relation_id, root_manager_id, client_id, from_manager_id, to_manager_id, operated_by, reason, customer_name_snapshot)
    VALUES (v_existing_relation, v_root, v_client_id, NULL, v_manager_id, v_manager_id, '建档', v_customer_name);
    RETURN v_client_id;
  END IF;

  BEGIN
    INSERT INTO public.client_relations (manager_id, client_id, status, notes, root_manager_id, customer_name, client_phone_normalized)
    VALUES (v_manager_id, v_client_id, 'active', COALESCE(p_notes, ''), v_root, v_customer_name, v_phone);

    SELECT id INTO v_existing_relation
    FROM public.client_relations
    WHERE manager_id = v_manager_id AND client_id = v_client_id AND status = 'active';

    INSERT INTO public.client_assignment_history (relation_id, root_manager_id, client_id, from_manager_id, to_manager_id, operated_by, reason, customer_name_snapshot)
    VALUES (v_existing_relation, v_root, v_client_id, NULL, v_manager_id, v_manager_id, '建档', v_customer_name);
  EXCEPTION
    WHEN unique_violation THEN
      SELECT cr.manager_id INTO v_existing_manager
      FROM public.client_relations cr
      WHERE cr.root_manager_id = v_root AND cr.client_id = v_client_id AND cr.status = 'active'
      LIMIT 1;
      SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
      FROM public.profiles WHERE id = v_existing_manager;
      RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
        USING ERRCODE = '23505';
  END;

  RETURN v_client_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_manager_client(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_manager_client(text, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.create_manager_client(text, text, text) FROM anon;

-- ============ 二、bind_manager_by_invite_code：写公司根 + 冲突中文转换 ============
CREATE OR REPLACE FUNCTION public.bind_manager_by_invite_code(p_invite_code text, p_root_manager_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_relation_id UUID;
  v_normalized TEXT;
  v_root UUID;
  v_owner_id UUID;
  v_owner_name TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);

  SELECT * INTO v_manager
    FROM managers
   WHERE invite_code = v_normalized
     AND COALESCE(is_example, false) = false
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION '邀请码无效' USING ERRCODE = 'P0002';
  END IF;

  IF p_root_manager_id IS NOT NULL THEN
    IF COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = p_root_manager_id),
         p_root_manager_id
       ) IS DISTINCT FROM COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = v_manager.id),
         v_manager.id
       ) THEN
      RAISE EXCEPTION '该健康管理师不属于当前企业，请返回本企业健康管理师列表重新选择' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager.id);

  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text, 11));

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = v_manager.id;

  IF v_relation_id IS NULL THEN
    IF v_root IS NOT NULL THEN
      SELECT cr.manager_id INTO v_owner_id
      FROM client_relations cr
      WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root
        AND cr.status = 'active' AND cr.manager_id <> v_manager.id
      LIMIT 1;
      IF v_owner_id IS NOT NULL THEN
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
      END IF;
    END IF;
    BEGIN
      INSERT INTO client_relations (manager_id, client_id, root_manager_id, status, last_contact_at)
      VALUES (v_manager.id, v_uid, v_root, 'active', NOW())
      RETURNING id INTO v_relation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_owner_id
        FROM client_relations cr
        WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root AND cr.status = 'active'
        LIMIT 1;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;
  ELSE
    BEGIN
      UPDATE client_relations
         SET status = 'active', root_manager_id = v_root, updated_at = NOW(), last_contact_at = NOW()
       WHERE id = v_relation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_owner_id
        FROM client_relations cr
        WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root AND cr.status = 'active'
          AND cr.manager_id <> v_manager.id
        LIMIT 1;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;
  END IF;

  RETURN json_build_object('success', true, 'manager_id', v_manager.id, 'relation_id', v_relation_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_by_invite_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_by_invite_code(text, uuid) TO authenticated;

-- ============ 三、bind_manager_from_card：写公司根 + 冲突中文转换 ============
CREATE OR REPLACE FUNCTION public.bind_manager_from_card(p_manager_id uuid, p_invite_code text, p_root_manager_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_relation_id UUID;
  v_normalized TEXT;
  v_root UUID;
  v_owner_id UUID;
  v_owner_name TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  IF COALESCE(v_manager.is_example, false) THEN
    RAISE EXCEPTION '示例管理师不可绑定，请使用真实管理师的邀请码' USING ERRCODE = '22023';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);
  IF v_manager.invite_code IS NULL OR v_manager.invite_code <> v_normalized THEN
    RAISE EXCEPTION '邀请码错误' USING ERRCODE = '22023';
  END IF;

  IF p_root_manager_id IS NOT NULL THEN
    IF COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = p_root_manager_id),
         p_root_manager_id
       ) IS DISTINCT FROM COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = v_manager.id),
         v_manager.id
       ) THEN
      RAISE EXCEPTION '该健康管理师不属于当前企业，请返回本企业健康管理师列表重新选择' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager.id);

  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text, 11));

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    IF v_root IS NOT NULL THEN
      SELECT cr.manager_id INTO v_owner_id
      FROM client_relations cr
      WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root
        AND cr.status = 'active' AND cr.manager_id <> p_manager_id
      LIMIT 1;
      IF v_owner_id IS NOT NULL THEN
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
      END IF;
    END IF;
    BEGIN
      INSERT INTO client_relations (manager_id, client_id, root_manager_id, status, last_contact_at)
      VALUES (p_manager_id, v_uid, v_root, 'active', NOW())
      RETURNING id INTO v_relation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_owner_id
        FROM client_relations cr
        WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root AND cr.status = 'active'
        LIMIT 1;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;
  ELSE
    BEGIN
      UPDATE client_relations
         SET status = 'active', root_manager_id = v_root, updated_at = NOW(), last_contact_at = NOW()
       WHERE id = v_relation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_owner_id
        FROM client_relations cr
        WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root AND cr.status = 'active'
          AND cr.manager_id <> p_manager_id
        LIMIT 1;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;
  END IF;

  RETURN json_build_object('success', true, 'manager_id', p_manager_id, 'relation_id', v_relation_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_from_card(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_card(uuid, text, uuid) TO authenticated;

-- ============ 四、bind_manager_from_public：写公司根 + 冲突中文转换 ============
CREATE OR REPLACE FUNCTION public.bind_manager_from_public(p_manager_id uuid, p_root_manager_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_manager public.managers%ROWTYPE;
  v_role text;
  v_relation_id uuid;
  v_root UUID;
  v_owner_id UUID;
  v_owner_name TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_manager FROM public.managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT role::text INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role IS DISTINCT FROM 'user' THEN
    RETURN json_build_object('success', false, 'reason', 'role_not_user', 'manager_id', p_manager_id);
  END IF;

  IF COALESCE(v_manager.is_example, false) THEN
    RETURN json_build_object('success', false, 'reason', 'example_manager', 'manager_id', p_manager_id);
  END IF;

  IF v_manager.certification_status IS DISTINCT FROM 'approved' THEN
    RETURN json_build_object('success', false, 'reason', 'manager_not_approved', 'manager_id', p_manager_id);
  END IF;

  IF p_root_manager_id IS NOT NULL THEN
    IF COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = p_root_manager_id),
         p_root_manager_id
       ) IS DISTINCT FROM COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = v_manager.id),
         v_manager.id
       ) THEN
      RAISE EXCEPTION '该健康管理师不属于当前企业，请返回本企业健康管理师列表重新选择' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager.id);

  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text, 11));

  SELECT id INTO v_relation_id
  FROM public.client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    IF v_root IS NOT NULL THEN
      SELECT cr.manager_id INTO v_owner_id
      FROM public.client_relations cr
      WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root
        AND cr.status = 'active' AND cr.manager_id <> p_manager_id
      LIMIT 1;
      IF v_owner_id IS NOT NULL THEN
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
      END IF;
    END IF;
    BEGIN
      INSERT INTO public.client_relations (manager_id, client_id, root_manager_id, status, last_contact_at)
      VALUES (p_manager_id, v_uid, v_root, 'active', NOW())
      RETURNING id INTO v_relation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_owner_id
        FROM public.client_relations cr
        WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root AND cr.status = 'active'
        LIMIT 1;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;
  ELSE
    BEGIN
      UPDATE public.client_relations
         SET status = 'active', root_manager_id = v_root, updated_at = NOW(), last_contact_at = NOW()
       WHERE id = v_relation_id;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT cr.manager_id INTO v_owner_id
        FROM public.client_relations cr
        WHERE cr.client_id = v_uid AND cr.root_manager_id = v_root AND cr.status = 'active'
          AND cr.manager_id <> p_manager_id
        LIMIT 1;
        SELECT COALESCE(NULLIF(btrim(nickname), ''), '未命名员工') INTO v_owner_name
        FROM public.profiles WHERE id = v_owner_id;
        RAISE EXCEPTION '该客户已由「%」负责，如需变更请联系企业管理员转移', COALESCE(v_owner_name, '同事')
          USING ERRCODE = '23505';
    END;
  END IF;

  RETURN json_build_object('success', true, 'reason', 'bound', 'manager_id', p_manager_id, 'relation_id', v_relation_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_from_public(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_public(uuid, uuid) TO authenticated;

-- ============ 五、register_shop_member：重复关系静默、其余异常记日志 ============
create or replace function public.register_shop_member(p_root_manager_id uuid)
returns table(member_id uuid, member_number text, first_entered_at timestamp with time zone, created boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_sequence bigint;
  v_prefix text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.profiles
    where id = v_uid and role::text = 'user' and coalesce(is_disabled, false) = false
  ) then
    raise exception '当前账号不能登记商城会员' using errcode = '42501';
  end if;

  if public.get_enterprise_root_manager_id(p_root_manager_id) is distinct from p_root_manager_id
     or not public.is_public_enterprise_content_root(p_root_manager_id) then
    raise exception '商城不存在或已停用' using errcode = '22023';
  end if;

  return query
  select sm.id, sm.member_number, sm.first_entered_at, false
  from public.shop_members sm
  where sm.root_manager_id = p_root_manager_id and sm.client_id = v_uid;
  if found then return; end if;

  insert into public.shop_member_counters(root_manager_id, last_value)
  values (p_root_manager_id, 1)
  on conflict (root_manager_id) do update
    set last_value = public.shop_member_counters.last_value + 1
  returning last_value into v_sequence;

  v_prefix := public.shop_member_prefix(p_root_manager_id);

  return query
  insert into public.shop_members(root_manager_id, client_id, member_sequence, member_number)
  values (p_root_manager_id, v_uid, v_sequence, v_prefix || '-' || lpad(v_sequence::text, 6, '0'))
  on conflict (root_manager_id, client_id) do nothing
  returning shop_members.id, shop_members.member_number, shop_members.first_entered_at, true;

  begin
    insert into public.client_relations (manager_id, client_id, root_manager_id, status, created_at, updated_at)
    values (p_root_manager_id, v_uid, p_root_manager_id, 'active', now(), now())
    on conflict do nothing;
  exception
    when unique_violation then
      null;
    when others then
      raise warning 'register_shop_member 补建客户关系失败: %', sqlerrm;
  end;

  if not found then
    return query
    select sm.id, sm.member_number, sm.first_entered_at, false
    from public.shop_members sm
    where sm.root_manager_id = p_root_manager_id and sm.client_id = v_uid;
  end if;
end;
$function$;

REVOKE ALL ON FUNCTION public.register_shop_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_shop_member(uuid) TO authenticated;