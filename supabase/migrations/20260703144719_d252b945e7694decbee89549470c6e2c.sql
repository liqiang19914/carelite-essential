CREATE OR REPLACE FUNCTION public.transfer_manager_clients(
  p_from_manager_id uuid,
  p_to_manager_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_moved_count integer := 0;
  v_conflict_count integer := 0;
  v_from_nickname text;
  v_to_nickname text;
  v_to_is_disabled boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_from_manager_id IS NULL OR p_to_manager_id IS NULL THEN
    RAISE EXCEPTION '请选择转出人和接收人' USING ERRCODE = '22023';
  END IF;

  IF p_from_manager_id = p_to_manager_id THEN
    RAISE EXCEPTION '接收人不能与转出人相同' USING ERRCODE = '22023';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业主或企业管理员可转让客户' USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_enterprise_member_for_admin(p_from_manager_id, v_uid)
     OR NOT public.is_enterprise_member_for_admin(p_to_manager_id, v_uid) THEN
    RAISE EXCEPTION '无权在当前企业范围外转让客户' USING ERRCODE = '42501';
  END IF;

  SELECT nickname::text
    INTO v_from_nickname
  FROM public.profiles
  WHERE id = p_from_manager_id;

  SELECT nickname::text, COALESCE(is_disabled, false)
    INTO v_to_nickname, v_to_is_disabled
  FROM public.profiles
  WHERE id = p_to_manager_id;

  IF v_to_is_disabled THEN
    RAISE EXCEPTION '接收账号已被禁用，请先启用后再转让' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*)::integer
    INTO v_conflict_count
  FROM public.client_relations src
  WHERE src.manager_id = p_from_manager_id
    AND EXISTS (
      SELECT 1
      FROM public.client_relations dst
      WHERE dst.manager_id = p_to_manager_id
        AND dst.client_id = src.client_id
    );

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION '接收人名下已存在 % 条相同客户关系，暂不能批量转让，请联系平台处理', v_conflict_count
      USING ERRCODE = '23505';
  END IF;

  BEGIN
    UPDATE public.client_relations
       SET manager_id = p_to_manager_id,
           updated_at = NOW()
     WHERE manager_id = p_from_manager_id;

    GET DIAGNOSTICS v_moved_count = ROW_COUNT;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION '接收人名下已存在相同客户，暂不能批量转让，请联系平台处理'
        USING ERRCODE = '23505';
  END;

  IF v_moved_count > 0 THEN
    BEGIN
      INSERT INTO public.operation_logs (
        user_id, action, detail, module, metadata
      )
      VALUES (
        v_uid,
        '转让客户',
        format(
          '将「%s」名下 %s 条客户关系转让给「%s」',
          COALESCE(v_from_nickname, p_from_manager_id::text),
          v_moved_count,
          COALESCE(v_to_nickname, p_to_manager_id::text)
        ),
        '企业中心',
        jsonb_build_object(
          'from_manager_id', p_from_manager_id,
          'to_manager_id', p_to_manager_id,
          'moved_count', v_moved_count
        )
      );
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING '写入客户转让日志失败: %', SQLERRM;
    END;
  END IF;

  RETURN v_moved_count;
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_manager_clients(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_manager_clients(uuid, uuid) TO authenticated;
