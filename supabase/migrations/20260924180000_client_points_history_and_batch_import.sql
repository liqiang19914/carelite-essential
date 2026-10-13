-- 1) 积分历史 RPC：商户企业管理员查看某个客户的积分余额 + 最近流水
--    points_balances / points_ledger 有 RLS，merchant 身份直接查不到别人的，用 SECURITY DEFINER 绕过。
--    校验：仅企业管理员 + 该客户必须属于本企业（client_relations 关联企业根/子员工）。
CREATE OR REPLACE FUNCTION public.get_client_points_overview(p_client_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_balance int := 0;
  v_total_earned int := 0;
  v_total_spent int := 0;
  v_ledger jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN jsonb_build_object('balance', 0, 'total_earned', 0, 'total_spent', 0, 'ledger', '[]'::jsonb);
  END IF;

  -- 校验客户属于本企业
  PERFORM 1
  FROM public.client_relations cr
  WHERE cr.client_id = p_client_id
    AND cr.manager_id IN (
      SELECT v_root AS mid
      UNION
      SELECT p.id FROM public.profiles p
      WHERE p.parent_manager_id = v_root AND p.role = 'manager'
    )
    AND cr.status IS DISTINCT FROM 'deleted'
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('balance', 0, 'total_earned', 0, 'total_spent', 0, 'ledger', '[]'::jsonb);
  END IF;

  SELECT COALESCE(pb.balance, 0), COALESCE(pb.total_earned, 0), COALESCE(pb.total_spent, 0)
  INTO v_balance, v_total_earned, v_total_spent
  FROM public.points_balances pb
  WHERE pb.user_id = p_client_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', pl.id,
    'delta', pl.delta,
    'balance_after', pl.balance_after,
    'reason_code', pl.reason_code,
    'reason_text', pl.reason_text,
    'created_at', pl.created_at
  ) ORDER BY pl.created_at DESC, pl.id DESC), '[]'::jsonb)
  INTO v_ledger
  FROM public.points_ledger pl
  WHERE pl.user_id = p_client_id
  LIMIT 50;

  RETURN jsonb_build_object(
    'balance', v_balance,
    'total_earned', v_total_earned,
    'total_spent', v_total_spent,
    'ledger', v_ledger
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_client_points_overview(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_client_points_overview(uuid) TO authenticated, service_role;


-- 2) 批量导入客户属性 RPC
--    输入 jsonb 数组：[{phone, customer_name, owner_name, store_name, points, status, notes}, ...]
--    匹配键=手机号（profiles.phone），客户必须属于本企业。
--    积分=覆盖式（Excel 填多少就是多少），差额走 manual_adjustment 流水。
CREATE OR REPLACE FUNCTION public.batch_update_client_attributes(p_updates jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_item jsonb;
  v_phone text;
  v_client_id uuid;
  v_relation_id uuid;
  v_updates text[];
  v_errors text;
  v_success_count int := 0;
  v_failed_count int := 0;
  v_results jsonb := '[]'::jsonb;
  v_member_ids uuid[];
  v_owner_id uuid;
  v_store_id uuid;
  v_current_balance int;
  v_new_points int;
  v_delta int;
  v_idem text;
  v_member_rec record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN jsonb_build_object('success', 0, 'failed', 0, 'results', '[]'::jsonb);
  END IF;

  -- 预算本企业成员 ID（根 + 子员工），用于校验客户归属和归属员工匹配
  v_member_ids := ARRAY(
    SELECT v_root AS mid
    UNION
    SELECT p.id FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  );

FOR v_item IN SELECT * FROM jsonb_array_elements(p_updates) LOOP
  BEGIN
    v_phone := NULLIF(TRIM(BTRIM(v_item->>'phone')), '');
    v_updates := ARRAY[]::text[];

    IF v_phone IS NULL OR v_phone !~ '^1[0-9]{10}$' THEN
      v_failed_count := v_failed_count + 1;
      v_results := v_results || jsonb_build_object(
        'row', v_failed_count + v_success_count,
        'phone', COALESCE(v_phone, ''),
        'ok', false,
        'error', '手机号格式不正确'
      );
      CONTINUE;
    END IF;

    -- 按手机号找客户 profile
    SELECT id INTO v_client_id
    FROM public.profiles
    WHERE phone = v_phone
    LIMIT 1;

    IF v_client_id IS NULL THEN
      v_failed_count := v_failed_count + 1;
      v_results := v_results || jsonb_build_object(
        'row', v_failed_count + v_success_count,
        'phone', v_phone,
        'ok', false,
        'error', '未找到该手机号对应的客户'
      );
      CONTINUE;
    END IF;

    -- 找该客户在本企业的 client_relation（优先 active）
    SELECT cr.id INTO v_relation_id
    FROM public.client_relations cr
    WHERE cr.client_id = v_client_id
      AND cr.manager_id = ANY(v_member_ids)
      AND cr.status IS DISTINCT FROM 'deleted'
    ORDER BY (cr.status = 'active') DESC, cr.updated_at DESC NULLS LAST, cr.id DESC
    LIMIT 1;

    IF v_relation_id IS NULL THEN
      v_failed_count := v_failed_count + 1;
      v_results := v_results || jsonb_build_object(
        'row', v_failed_count + v_success_count,
        'phone', v_phone,
        'ok', false,
        'error', '该客户不属于本企业'
      );
      CONTINUE;
    END IF;

    -- 1. 更新 customer_name（档案姓名）
    IF v_item ? 'customer_name' AND NULLIF(TRIM(v_item->>'customer_name'), '') IS NOT NULL THEN
      UPDATE public.client_relations
      SET customer_name = TRIM(v_item->>'customer_name'), updated_at = now()
      WHERE id = v_relation_id;
      v_updates := v_updates || '档案姓名';
    END IF;

    -- 2. 更新 notes（备注）
    IF v_item ? 'notes' AND v_item->>'notes' IS NOT NULL THEN
      UPDATE public.client_relations
      SET notes = v_item->>'notes', updated_at = now()
      WHERE id = v_relation_id;
      v_updates := v_updates || '备注';
    END IF;

    -- 3. 更新 status（状态）
    IF v_item ? 'status' AND NULLIF(TRIM(v_item->>'status'), '') IS NOT NULL THEN
      IF v_item->>'status' IN ('active', 'inactive', 'pending') THEN
        UPDATE public.client_relations
        SET status = v_item->>'status', updated_at = now()
        WHERE id = v_relation_id;
        v_updates := v_updates || '状态';
      END IF;
    END IF;

    -- 4. 更新归属员工（按昵称匹配本企业管理员）
    IF v_item ? 'owner_name' AND NULLIF(TRIM(v_item->>'owner_name'), '') IS NOT NULL THEN
      SELECT p.id INTO v_owner_id
      FROM public.profiles p
      WHERE p.id = ANY(v_member_ids)
        AND p.id <> v_root
        AND COALESCE(p.nickname, '') = TRIM(v_item->>'owner_name')
      LIMIT 1;

      IF v_owner_id IS NOT NULL THEN
        UPDATE public.client_relations
        SET manager_id = v_owner_id, updated_at = now()
        WHERE id = v_relation_id;
        v_updates := v_updates || '归属员工';
      ELSE
        -- 归属员工匹配不到不中断，只记录问题
        v_errors := COALESCE(v_errors, '') || '归属员工「' || v_item->>'owner_name' || '」未匹配到;';
      END IF;
    END IF;

    -- 5. 更新归属门店（按门店名匹配本企业门店）
    IF v_item ? 'store_name' AND NULLIF(TRIM(v_item->>'store_name'), '') IS NOT NULL THEN
      SELECT s.id INTO v_store_id
      FROM public.stores s
      WHERE s.root_manager_id = v_root
        AND s.name = TRIM(v_item->>'store_name')
        AND s.status = 'active'
      LIMIT 1;

      IF v_store_id IS NOT NULL THEN
        -- 旧绑定置 unbound（与 bind_user_to_store 同口径）
        UPDATE public.user_store_bindings
        SET status = 'unbound', updated_at = now()
        WHERE user_id = v_client_id AND status = 'active';

        -- 插入新绑定
        INSERT INTO public.user_store_bindings (user_id, store_id, status, bound_at, created_at, updated_at)
        VALUES (v_client_id, v_store_id, 'active', now(), now(), now())
        ON CONFLICT (user_id, store_id)
        DO UPDATE SET status = 'active', bound_at = now(), updated_at = now();

        v_updates := v_updates || '归属门店';
      ELSE
        v_errors := COALESCE(v_errors, '') || '门店「' || v_item->>'store_name' || '」未匹配到;';
      END IF;
    END IF;

    -- 6. 更新积分（覆盖式）
    IF v_item ? 'points' AND v_item->>'points' IS NOT NULL THEN
      v_new_points := TRIM(v_item->>'points')::int;
      v_new_points := GREATEST(v_new_points, 0);

      SELECT COALESCE(pb.balance, 0) INTO v_current_balance
      FROM public.points_balances pb
      WHERE pb.user_id = v_client_id;

      v_delta := v_new_points - v_current_balance;

      IF v_delta <> 0 THEN
        -- 确保 balance 行存在
        INSERT INTO public.points_balances (user_id, balance, total_earned, total_spent)
        VALUES (v_client_id, 0, 0, 0)
        ON CONFLICT (user_id) DO NOTHING;

        -- 锁定行
        SELECT balance INTO v_current_balance
        FROM public.points_balances
        WHERE user_id = v_client_id
        FOR UPDATE;

        v_delta := v_new_points - v_current_balance;

        IF v_delta <> 0 THEN
          v_idem := 'batch_import_' || v_client_id::text || '_' || extract(epoch from now())::bigint::text;

          INSERT INTO public.points_ledger (user_id, delta, balance_after, reason_code, reason_text, operator_id, idempotency_key)
          VALUES (v_client_id, v_delta, v_new_points, 'manual_adjustment', '批量导入覆盖积分', v_uid, v_idem);

          UPDATE public.points_balances
          SET balance = v_new_points,
              total_earned = total_earned + GREATEST(v_delta, 0),
              total_spent = total_spent + GREATEST(-v_delta, 0),
              updated_at = now()
          WHERE user_id = v_client_id;
        END IF;

        v_updates := v_updates || '积分';
      END IF;
    END IF;

    v_success_count := v_success_count + 1;
    v_results := v_results || jsonb_build_object(
      'row', v_success_count + v_failed_count,
      'phone', v_phone,
      'ok', true,
      'fields', array_to_string(v_updates, '、'),
      'warning', COALESCE(v_errors, '')
    );
    v_errors := NULL;
  EXCEPTION WHEN OTHERS THEN
    v_failed_count := v_failed_count + 1;
    v_results := v_results || jsonb_build_object(
      'row', v_success_count + v_failed_count,
      'phone', COALESCE(v_phone, ''),
      'ok', false,
      'error', SQLERRM
    );
    v_errors := NULL;
  END;
END LOOP;

  RETURN jsonb_build_object(
    'success', v_success_count,
    'failed', v_failed_count,
    'results', v_results
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.batch_update_client_attributes(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.batch_update_client_attributes(jsonb) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
