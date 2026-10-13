-- ============================================================================
-- 企业中心 + 归属管理：多员工组织协同能力
-- ============================================================================

-- 1) parent_manager_id 外键 + 注释（幂等，列本身已存在）
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_parent_manager_id_fkey'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_parent_manager_id_fkey
      FOREIGN KEY (parent_manager_id) REFERENCES public.profiles(id) ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON COLUMN public.profiles.parent_manager_id IS
  '归属主管理师 id（企业 boss）。boss=null；员工=boss.id';
COMMENT ON COLUMN public.profiles.sub_role IS
  '员工子角色：admin(企业管理员) | health_manager(健康管理师) | service/analyst(兼容旧数据)。boss 保持空串';

-- 2) 索引：企业员工集合 + 归属管理页 ORDER BY + LIMIT
CREATE INDEX IF NOT EXISTS idx_profiles_parent_role_subrole
  ON public.profiles (parent_manager_id, sub_role, id)
  WHERE role = 'manager' AND parent_manager_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_client_relations_manager_created
  ON public.client_relations (manager_id, created_at DESC);

-- 3) helper: 企业根 id
CREATE OR REPLACE FUNCTION public.get_enterprise_root_manager_id(uid uuid)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p.role = 'manager' AND p.parent_manager_id IS NULL THEN p.id
    WHEN p.role = 'manager' AND p.parent_manager_id IS NOT NULL THEN p.parent_manager_id
    ELSE NULL
  END
  FROM public.profiles p
  WHERE p.id = uid;
$$;

-- 4) helper: 是否企业管理员 (boss OR sub_role='admin' 且未禁用)
CREATE OR REPLACE FUNCTION public.is_enterprise_admin(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = uid
      AND role = 'manager'
      AND COALESCE(is_disabled, false) = false
      AND (parent_manager_id IS NULL OR sub_role = 'admin')
  );
$$;

-- 5) helper: 目标 member_manager_id 属于 uid 所在企业（供 RLS 使用）
CREATE OR REPLACE FUNCTION public.is_enterprise_member_for_admin(member_manager_id uuid, uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles caller
    JOIN public.profiles member ON member.id = member_manager_id
    WHERE caller.id = uid
      AND caller.role = 'manager'
      AND COALESCE(caller.is_disabled, false) = false
      AND (caller.parent_manager_id IS NULL OR caller.sub_role = 'admin')
      AND member.role = 'manager'
      AND (
        -- 场景 A：调用者是 boss，成员是自己或直属员工
        (caller.parent_manager_id IS NULL
          AND (member.id = caller.id OR member.parent_manager_id = caller.id))
        OR
        -- 场景 B：调用者是 sub_role='admin' 员工，成员归属于同一 boss（含 boss 本人）
        (caller.sub_role = 'admin' AND caller.parent_manager_id IS NOT NULL
          AND (member.id = caller.parent_manager_id OR member.parent_manager_id = caller.parent_manager_id))
      )
  );
$$;

REVOKE ALL ON FUNCTION public.get_enterprise_root_manager_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_enterprise_root_manager_id(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.is_enterprise_admin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_enterprise_admin(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.is_enterprise_member_for_admin(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_enterprise_member_for_admin(uuid, uuid) TO authenticated;

-- 6) RLS 扩展
DROP POLICY IF EXISTS "Enterprise admin can view enterprise client relations" ON public.client_relations;
CREATE POLICY "Enterprise admin can view enterprise client relations"
  ON public.client_relations FOR SELECT
  USING (public.is_enterprise_member_for_admin(manager_id, auth.uid()));

DROP POLICY IF EXISTS "Enterprise admin can view enterprise client tags" ON public.client_tags;
CREATE POLICY "Enterprise admin can view enterprise client tags"
  ON public.client_tags FOR SELECT
  USING (public.is_enterprise_member_for_admin(manager_id, auth.uid()));

DROP POLICY IF EXISTS "Enterprise admin can view enterprise tag relations" ON public.client_tag_relations;
CREATE POLICY "Enterprise admin can view enterprise tag relations"
  ON public.client_tag_relations FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.client_relations cr
    WHERE cr.id = client_tag_relations.client_relation_id
      AND public.is_enterprise_member_for_admin(cr.manager_id, auth.uid())
  ));

DROP POLICY IF EXISTS "Enterprise admin can view enterprise follow ups" ON public.follow_up_records;
CREATE POLICY "Enterprise admin can view enterprise follow ups"
  ON public.follow_up_records FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.client_relations cr
    WHERE cr.id = follow_up_records.client_relation_id
      AND public.is_enterprise_member_for_admin(cr.manager_id, auth.uid())
  ));

-- Boss 对直属员工的 managers 行 SELECT/UPDATE/INSERT
DROP POLICY IF EXISTS "Boss can view direct employee managers" ON public.managers;
CREATE POLICY "Boss can view direct employee managers"
  ON public.managers FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = managers.id AND p.parent_manager_id = auth.uid()
  ));

DROP POLICY IF EXISTS "Boss can update direct employee managers" ON public.managers;
CREATE POLICY "Boss can update direct employee managers"
  ON public.managers FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = managers.id AND p.parent_manager_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = managers.id AND p.parent_manager_id = auth.uid()
  ));

DROP POLICY IF EXISTS "Boss can insert direct employee managers" ON public.managers;
CREATE POLICY "Boss can insert direct employee managers"
  ON public.managers FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = managers.id AND p.parent_manager_id = auth.uid()
  ));

-- Boss 对直属员工知识库文档 FOR ALL
DROP POLICY IF EXISTS "Boss can manage direct employee knowledge docs" ON public.manager_knowledge_documents;
CREATE POLICY "Boss can manage direct employee knowledge docs"
  ON public.manager_knowledge_documents FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = manager_knowledge_documents.manager_id
      AND p.parent_manager_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = manager_knowledge_documents.manager_id
      AND p.parent_manager_id = auth.uid()
  ));

-- 7) RPC: 企业客户 with owner，分页 + 搜索 + 归属过滤
CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0,
  p_search text DEFAULT NULL,
  p_owner_manager_id uuid DEFAULT NULL
)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamptz,
  relation_created_at timestamptz,
  nickname text,
  phone text,
  avatar_url text,
  owner_manager_id uuid,
  owner_manager_nickname text,
  owner_manager_phone text,
  owner_sub_role text,
  owner_is_disabled boolean,
  total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT public.is_enterprise_admin(v_uid) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    RETURN;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

  RETURN QUERY
  WITH members AS (
    SELECT v_root AS mid
    UNION
    SELECT p.id
    FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  scoped AS (
    SELECT cr.*
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
      AND (p_owner_manager_id IS NULL OR cr.manager_id = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = cr.client_id
            AND (cp.nickname ILIKE '%' || v_search || '%'
                 OR cp.phone ILIKE '%' || v_search || '%')
        )
      )
  )
  SELECT
    s.id AS relation_id,
    s.client_id,
    s.status::text,
    s.notes,
    s.last_contact_at,
    s.created_at AS relation_created_at,
    cp.nickname::text,
    cp.phone::text,
    cp.avatar_url,
    s.manager_id AS owner_manager_id,
    op.nickname::text AS owner_manager_nickname,
    op.phone::text AS owner_manager_phone,
    COALESCE(op.sub_role, '')::text AS owner_sub_role,
    COALESCE(op.is_disabled, false) AS owner_is_disabled,
    COUNT(*) OVER() AS total_count
  FROM scoped s
  LEFT JOIN public.profiles cp ON cp.id = s.client_id
  LEFT JOIN public.profiles op ON op.id = s.manager_id
  ORDER BY s.created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(int, int, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(int, int, text, uuid) TO authenticated;

-- 8) get_manager_knowledge_settings 授权扩展：boss 可读直属员工
CREATE OR REPLACE FUNCTION public.get_manager_knowledge_settings(p_manager_id uuid DEFAULT NULL::uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_is_admin BOOLEAN;
  v_target UUID;
  v_row RECORD;
  v_doc_count INT;
  v_auto_count INT;
  v_last_train TIMESTAMPTZ;
  v_authorized BOOLEAN := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  SELECT public.is_admin(v_uid) INTO v_is_admin;

  IF p_manager_id IS NULL THEN
    v_target := v_uid;
    v_authorized := true;
  ELSIF v_is_admin THEN
    v_target := p_manager_id;
    v_authorized := true;
  ELSIF p_manager_id = v_uid THEN
    v_target := v_uid;
    v_authorized := true;
  ELSE
    IF EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = p_manager_id AND parent_manager_id = v_uid
    ) THEN
      v_target := p_manager_id;
      v_authorized := true;
    END IF;
  END IF;

  IF NOT v_authorized THEN
    RETURN json_build_object('error', '权限不足');
  END IF;

  SELECT m.id, m.knowledge_index_id, m.knowledge_index_status,
         m.knowledge_model, m.knowledge_system_prompt
    INTO v_row
    FROM public.managers m
   WHERE m.id = v_target;

  IF NOT FOUND THEN
    RETURN json_build_object('error', '管理师不存在');
  END IF;

  SELECT COUNT(*) FILTER (WHERE source = 'user_upload'),
         COUNT(*) FILTER (WHERE source = 'auto_sync'),
         MAX(updated_at) FILTER (WHERE source = 'auto_sync')
    INTO v_doc_count, v_auto_count, v_last_train
    FROM public.manager_knowledge_documents
   WHERE manager_id = v_target;

  RETURN json_build_object(
    'manager_id', v_row.id,
    'knowledge_index_id', v_row.knowledge_index_id,
    'knowledge_index_status', COALESCE(v_row.knowledge_index_status, 'none'),
    'knowledge_model', COALESCE(v_row.knowledge_model, 'qwen3.6-plus'),
    'knowledge_system_prompt', v_row.knowledge_system_prompt,
    'user_upload_count', COALESCE(v_doc_count, 0),
    'auto_sync_count', COALESCE(v_auto_count, 0),
    'last_train_at', v_last_train
  );
END;
$function$;

-- 9) 新 RPC: boss 或 admin 或本人对目标员工写知识库设置
CREATE OR REPLACE FUNCTION public.update_manager_knowledge_settings_for_manager(
  p_manager_id uuid,
  p_model text,
  p_system_prompt text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_authorized BOOLEAN := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;

  IF p_manager_id = v_uid THEN
    v_authorized := true;
  ELSIF public.is_admin(v_uid) THEN
    v_authorized := true;
  ELSIF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_manager_id AND parent_manager_id = v_uid
  ) THEN
    v_authorized := true;
  END IF;

  IF NOT v_authorized THEN
    RETURN json_build_object('error', '权限不足');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RETURN json_build_object('error', '管理师不存在');
  END IF;

  IF p_system_prompt IS NOT NULL AND length(p_system_prompt) > 2000 THEN
    p_system_prompt := substring(p_system_prompt, 1, 2000);
  END IF;

  UPDATE public.managers
     SET knowledge_model = COALESCE(NULLIF(trim(p_model), ''), 'qwen3.6-plus'),
         knowledge_system_prompt = NULLIF(trim(COALESCE(p_system_prompt, '')), ''),
         updated_at = NOW()
   WHERE id = p_manager_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_manager_knowledge_settings_for_manager(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_manager_knowledge_settings_for_manager(uuid, text, text) TO authenticated;

-- 10) 老员工 managers 行补齐（幂等）
INSERT INTO public.managers (
  id,
  certification_status,
  submitted_at,
  reviewed_at,
  reviewed_by,
  review_note,
  knowledge_index_status,
  knowledge_model,
  partner_card_display_name
)
SELECT
  p.id,
  'approved',
  p.created_at,
  NOW(),
  p.parent_manager_id,
  '(auto-backfill: enterprise center 迁移)',
  'none',
  'qwen3.6-plus',
  COALESCE(p.nickname, '健康管理师')
FROM public.profiles p
WHERE p.role = 'manager'
  AND p.parent_manager_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p.id)
ON CONFLICT (id) DO NOTHING;
