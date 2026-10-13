-- ============ 一、存量整理：默认昵称清洗（「用户86XXXXXXXXXXX」→「用户+后四位」） ============
UPDATE public.profiles
SET nickname = '用户' || right(nickname, 4),
    updated_at = now()
WHERE nickname ~ '^用户86[0-9]{11}$';

-- ============ 二、client_relations 扩展公司级字段 ============
ALTER TABLE public.client_relations
  ADD COLUMN IF NOT EXISTS root_manager_id uuid,
  ADD COLUMN IF NOT EXISTS customer_name text,
  ADD COLUMN IF NOT EXISTS client_phone_normalized text;

-- 回填：公司根、客户备注名、规范化手机号
UPDATE public.client_relations cr
SET root_manager_id = public.get_enterprise_root_manager_id(cr.manager_id),
    customer_name = COALESCE(NULLIF(btrim(p.nickname), ''), '未命名客户'),
    client_phone_normalized = NULLIF(public.normalize_cn_phone(p.phone), ''),
    updated_at = now()
FROM public.profiles p
WHERE p.id = cr.client_id
  AND (cr.root_manager_id IS NULL OR cr.customer_name IS NULL OR cr.client_phone_normalized IS NULL);

-- 兜底：无手机号档案的客户名
UPDATE public.client_relations
SET customer_name = '未命名客户'
WHERE customer_name IS NULL;

-- ============ 三、公司级唯一约束（部分索引，仅 active） ============
CREATE UNIQUE INDEX IF NOT EXISTS uq_client_relations_root_client
  ON public.client_relations (root_manager_id, client_id)
  WHERE status = 'active' AND root_manager_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_client_relations_root_phone
  ON public.client_relations (root_manager_id, client_phone_normalized)
  WHERE status = 'active' AND root_manager_id IS NOT NULL AND client_phone_normalized IS NOT NULL;

-- ============ 四、归属历史表 ============
CREATE TABLE IF NOT EXISTS public.client_assignment_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  relation_id uuid REFERENCES public.client_relations(id) ON DELETE CASCADE,
  root_manager_id uuid,
  client_id uuid NOT NULL,
  from_manager_id uuid,
  to_manager_id uuid,
  operated_by uuid,
  reason text,
  customer_name_snapshot text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cah_client ON public.client_assignment_history(client_id);
CREATE INDEX IF NOT EXISTS idx_cah_root_client ON public.client_assignment_history(root_manager_id, client_id);

-- 历史表只读入口走 RPC，不直接开放表权限

-- ============ 五、手机号不可编辑保护（平台超管与系统流程除外） ============
CREATE OR REPLACE FUNCTION public.protect_profiles_phone()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.is_admin(auth.uid())
     AND NEW.phone IS DISTINCT FROM OLD.phone THEN
    RAISE EXCEPTION '手机号不可修改，如需变更请联系平台' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_profiles_phone ON public.profiles;
CREATE TRIGGER trg_protect_profiles_phone
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.protect_profiles_phone();

-- ============ 六、重写建档：公司级唯一 + 中文提示 + 历史 ============
DROP FUNCTION IF EXISTS public.create_manager_client(text, text, text);

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

    -- 公司级查重：同一企业内该手机号已有客户档案
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

  -- 优先复用当前员工名下已有关系（含历史解除的）
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

-- ============ 七、客户备注名修改（不改 profiles，写关系级） ============
CREATE OR REPLACE FUNCTION public.rename_relation_client(p_client_id uuid, p_customer_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_root uuid;
  v_rel record;
  v_name text := NULLIF(btrim(COALESCE(p_customer_name, '')), '');
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF v_name IS NULL OR char_length(v_name) > 20 THEN
    RAISE EXCEPTION '客户姓名需为 1-20 个字符' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager_id);

  SELECT id, manager_id INTO v_rel
  FROM public.client_relations
  WHERE client_id = p_client_id AND root_manager_id = v_root AND status = 'active'
  LIMIT 1;

  IF v_rel.id IS NULL THEN
    RAISE EXCEPTION '未找到该客户，请确认其属于当前企业' USING ERRCODE = '22023';
  END IF;

  IF v_rel.manager_id <> v_manager_id AND NOT public.is_enterprise_admin(v_manager_id) THEN
    RAISE EXCEPTION '仅客户负责人或企业管理员可修改客户姓名' USING ERRCODE = '42501';
  END IF;

  UPDATE public.client_relations
  SET customer_name = v_name, updated_at = now()
  WHERE id = v_rel.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.rename_relation_client(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_relation_client(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rename_relation_client(uuid, text) FROM anon;

-- ============ 八、单客户转归属（企业管理员操作，写历史） ============
CREATE OR REPLACE FUNCTION public.transfer_relation_client(p_client_id uuid, p_target_manager_id uuid, p_reason text DEFAULT NULL::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_root uuid;
  v_rel record;
  v_target_nickname text;
  v_target_is_disabled boolean := false;
  v_dup_rel uuid;
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_manager_id) THEN
    RAISE EXCEPTION '仅企业主或企业管理员可转移客户归属' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager_id);

  SELECT id, manager_id, customer_name INTO v_rel
  FROM public.client_relations
  WHERE client_id = p_client_id AND root_manager_id = v_root AND status = 'active'
  LIMIT 1
  FOR UPDATE;

  IF v_rel.id IS NULL THEN
    RAISE EXCEPTION '未找到该客户，请确认其属于当前企业' USING ERRCODE = '22023';
  END IF;

  IF p_target_manager_id = v_rel.manager_id THEN
    RAISE EXCEPTION '该客户已由此人负责' USING ERRCODE = '22023';
  END IF;

  IF NOT public.is_enterprise_member_for_admin(p_target_manager_id, v_manager_id) THEN
    RAISE EXCEPTION '接收人不在当前企业，无法转移' USING ERRCODE = '42501';
  END IF;

  SELECT nickname::text, COALESCE(is_disabled, false) INTO v_target_nickname, v_target_is_disabled
  FROM public.profiles WHERE id = p_target_manager_id;

  IF v_target_is_disabled THEN
    RAISE EXCEPTION '接收账号已被禁用，请先启用后再转移' USING ERRCODE = '22023';
  END IF;

  -- 清理接收人名下同客户的历史关系，避免激活冲突
  SELECT id INTO v_dup_rel
  FROM public.client_relations
  WHERE root_manager_id = v_root AND client_id = p_client_id AND manager_id = p_target_manager_id AND status <> 'active'
  LIMIT 1;
  IF v_dup_rel IS NOT NULL THEN
    DELETE FROM public.client_relations WHERE id = v_dup_rel;
  END IF;

  UPDATE public.client_relations
  SET manager_id = p_target_manager_id, updated_at = now()
  WHERE id = v_rel.id;

  INSERT INTO public.client_assignment_history (relation_id, root_manager_id, client_id, from_manager_id, to_manager_id, operated_by, reason, customer_name_snapshot)
  VALUES (v_rel.id, v_root, p_client_id, v_rel.manager_id, p_target_manager_id, v_manager_id, NULLIF(btrim(COALESCE(p_reason, '')), ''), v_rel.customer_name);

  BEGIN
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      v_manager_id,
      '转移客户',
      format('将客户「%s」由「%s」转移给「%s」', COALESCE(v_rel.customer_name, '未命名客户'),
        COALESCE((SELECT nickname FROM public.profiles WHERE id = v_rel.manager_id), v_rel.manager_id::text),
        COALESCE(v_target_nickname, p_target_manager_id::text)),
      '客户管理',
      jsonb_build_object('client_id', p_client_id, 'from_manager_id', v_rel.manager_id, 'to_manager_id', p_target_manager_id)
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '写入操作日志失败: %', SQLERRM;
  END;

  RETURN v_rel.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.transfer_relation_client(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_relation_client(uuid, uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.transfer_relation_client(uuid, uuid, text) FROM anon;

-- ============ 九、归属历史查询（同企业内可查） ============
CREATE OR REPLACE FUNCTION public.get_client_assignment_history(p_client_id uuid)
RETURNS TABLE (
  id uuid,
  from_manager_id uuid,
  from_name text,
  to_manager_id uuid,
  to_name text,
  operated_by uuid,
  operator_name text,
  reason text,
  customer_name_snapshot text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_root uuid;
  v_has_relation boolean;
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager_id);

  SELECT EXISTS (
    SELECT 1 FROM public.client_relations
    WHERE client_id = p_client_id AND root_manager_id = v_root
  ) INTO v_has_relation;

  IF NOT v_has_relation THEN
    RAISE EXCEPTION '无权查看该客户的归属历史' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT h.id,
         h.from_manager_id,
         COALESCE(fp.nickname, ''::text),
         h.to_manager_id,
         COALESCE(tp.nickname, ''::text),
         h.operated_by,
         COALESCE(op.nickname, ''::text),
         COALESCE(h.reason, ''::text),
         COALESCE(h.customer_name_snapshot, ''::text),
         h.created_at
  FROM public.client_assignment_history h
  LEFT JOIN public.profiles fp ON fp.id = h.from_manager_id
  LEFT JOIN public.profiles tp ON tp.id = h.to_manager_id
  LEFT JOIN public.profiles op ON op.id = h.operated_by
  WHERE h.client_id = p_client_id AND h.root_manager_id = v_root
  ORDER BY h.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_client_assignment_history(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_client_assignment_history(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_assignment_history(uuid) FROM anon;