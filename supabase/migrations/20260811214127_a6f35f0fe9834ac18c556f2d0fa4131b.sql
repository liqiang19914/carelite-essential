-- 账号合并：把 source 名下的一切重指向 target，然后删掉 source。
-- 不手写表清单 —— 直接遍历系统目录里所有指向 profiles / auth.users 的外键列，
-- 以后新增业务表自动纳入，不会漏迁。合并不可逆，所以默认 dry_run 只统计不改数据。
CREATE OR REPLACE FUNCTION public.merge_user_accounts(
  p_source uuid,
  p_target uuid,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_moved jsonb := '{}'::jsonb;
  v_dropped jsonb := '{}'::jsonb;
  v_preview jsonb := '{}'::jsonb;
  r record;
  rr record;
  v_key text;
  v_n bigint;
  v_moved_n bigint;
  v_dropped_n bigint;
  v_src_phone text;
  v_tgt_phone text;
BEGIN
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以合并账号' USING ERRCODE = '42501';
  END IF;
  IF p_source IS NULL OR p_target IS NULL OR p_source = p_target THEN
    RAISE EXCEPTION '要合并的两个账号必须不同' USING ERRCODE = '22023';
  END IF;

  SELECT public.normalize_cn_phone(phone) INTO v_src_phone FROM public.profiles WHERE id = p_source;
  SELECT public.normalize_cn_phone(phone) INTO v_tgt_phone FROM public.profiles WHERE id = p_target;
  IF v_src_phone IS NULL OR v_tgt_phone IS NULL THEN
    RAISE EXCEPTION '账号不存在' USING ERRCODE = '23503';
  END IF;
  IF v_src_phone = '' OR v_src_phone <> v_tgt_phone THEN
    RAISE EXCEPTION '两个账号的手机号不一致，不能合并' USING ERRCODE = '22023';
  END IF;

  FOR r IN
    SELECT ns.nspname AS sch, cl.relname AS tbl, att.attname AS col
    FROM pg_constraint con
    JOIN pg_class cl ON cl.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = cl.relnamespace
    JOIN pg_class fcl ON fcl.oid = con.confrelid
    JOIN pg_namespace fns ON fns.oid = fcl.relnamespace
    JOIN pg_attribute att ON att.attrelid = cl.oid AND att.attnum = con.conkey[1]
    WHERE con.contype = 'f'
      AND array_length(con.conkey, 1) = 1
      AND ns.nspname = 'public'
      AND ((fns.nspname = 'public' AND fcl.relname = 'profiles')
        OR (fns.nspname = 'auth' AND fcl.relname = 'users'))
      AND att.attname <> 'id'
      AND cl.relname <> 'profile_merge_log'
    ORDER BY cl.relname, att.attname
  LOOP
    v_key := r.tbl || '.' || r.col;
    EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I = $1', r.sch, r.tbl, r.col)
      INTO v_n USING p_source;
    IF v_n = 0 THEN CONTINUE; END IF;

    IF p_dry_run THEN
      v_preview := v_preview || jsonb_build_object(v_key, v_n);
      CONTINUE;
    END IF;

    -- 积分余额一人一行：必须相加，不能把源账号的积分丢掉
    IF r.tbl = 'points_balances' AND EXISTS (SELECT 1 FROM public.points_balances WHERE user_id = p_target) THEN
      UPDATE public.points_balances t
      SET balance = t.balance + s.balance,
          total_earned = t.total_earned + s.total_earned,
          total_spent = t.total_spent + s.total_spent,
          updated_at = now()
      FROM public.points_balances s
      WHERE t.user_id = p_target AND s.user_id = p_source;
      DELETE FROM public.points_balances WHERE user_id = p_source;
      v_moved := v_moved || jsonb_build_object(v_key, v_n);
      CONTINUE;
    END IF;

    v_moved_n := 0;
    v_dropped_n := 0;
    BEGIN
      EXECUTE format('UPDATE %I.%I SET %I = $1 WHERE %I = $2', r.sch, r.tbl, r.col, r.col)
        USING p_target, p_source;
      v_moved_n := v_n;
    EXCEPTION WHEN unique_violation THEN
      -- 撞唯一键说明保留账号已有等价数据（例如同一商户的归属关系）：逐行迁，冲突行丢弃
      FOR rr IN EXECUTE format('SELECT ctid AS rid FROM %I.%I WHERE %I = $1', r.sch, r.tbl, r.col) USING p_source
      LOOP
        BEGIN
          EXECUTE format('UPDATE %I.%I SET %I = $1 WHERE ctid = $2', r.sch, r.tbl, r.col)
            USING p_target, rr.rid;
          v_moved_n := v_moved_n + 1;
        EXCEPTION WHEN unique_violation THEN
          EXECUTE format('DELETE FROM %I.%I WHERE ctid = $1', r.sch, r.tbl) USING rr.rid;
          v_dropped_n := v_dropped_n + 1;
        END;
      END LOOP;
    END;

    IF v_moved_n > 0 THEN v_moved := v_moved || jsonb_build_object(v_key, v_moved_n); END IF;
    IF v_dropped_n > 0 THEN v_dropped := v_dropped || jsonb_build_object(v_key, v_dropped_n); END IF;
  END LOOP;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true, 'source', p_source, 'target', p_target,
      'phone', v_tgt_phone, 'will_move', v_preview
    );
  END IF;

  -- 合并后同一个人只留一份默认档案
  UPDATE public.health_records
  SET is_default = false
  WHERE user_id = p_target
    AND is_default = true
    AND id <> (
      SELECT id FROM public.health_records
      WHERE user_id = p_target
      ORDER BY is_default DESC, created_at ASC
      LIMIT 1
    );

  INSERT INTO public.profile_merge_log (source_id, target_id, phone, moved, dropped, performed_by)
  VALUES (p_source, p_target, v_tgt_phone, v_moved, v_dropped, v_uid);

  -- 先删登录账号（会级联清掉档案），档案态账号没有登录账号时再兜底删档案
  DELETE FROM auth.users WHERE id = p_source;
  DELETE FROM public.profiles WHERE id = p_source;

  RETURN jsonb_build_object(
    'dry_run', false, 'source', p_source, 'target', p_target,
    'phone', v_tgt_phone, 'moved', v_moved, 'dropped', v_dropped
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.merge_user_accounts(uuid, uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.merge_user_accounts(uuid, uuid, boolean) TO authenticated, service_role;