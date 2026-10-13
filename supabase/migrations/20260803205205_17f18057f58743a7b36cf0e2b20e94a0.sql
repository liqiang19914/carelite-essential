-- ============================================================================
-- 健康饮食导图：RLS 边界 + 商户端邀请
-- ============================================================================

-- 读取判定 helper：客户是否在调用者（或其企业）名下且关系有效
CREATE OR REPLACE FUNCTION public.diet_map_is_my_client(p_client_id uuid, uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.client_relations cr
    WHERE cr.client_id = p_client_id
      AND cr.status = 'active'
      AND (cr.manager_id = uid OR public.is_enterprise_member_for_admin(cr.manager_id, uid))
  );
$$;

-- 模板：仅平台管理员可见可改（评分权重属客户方知识产权）
DROP POLICY IF EXISTS "Admin manage diet map templates" ON public.diet_map_templates;
CREATE POLICY "Admin manage diet map templates"
  ON public.diet_map_templates FOR ALL
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

-- 开放矩阵：管理员写，管理师只读自己企业根那一行
DROP POLICY IF EXISTS "Admin manage diet map grants" ON public.diet_map_grants;
CREATE POLICY "Admin manage diet map grants"
  ON public.diet_map_grants FOR ALL
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Manager view own enterprise diet map grants" ON public.diet_map_grants;
CREATE POLICY "Manager view own enterprise diet map grants"
  ON public.diet_map_grants FOR SELECT
  USING (root_manager_id = public.get_enterprise_root_manager_id(auth.uid()));

-- 评估结果：本人读、名下管理师读、管理员读；一律不允许前端直接写
DROP POLICY IF EXISTS "Users view own diet map assessments" ON public.diet_map_assessments;
CREATE POLICY "Users view own diet map assessments"
  ON public.diet_map_assessments FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Manager view client diet map assessments" ON public.diet_map_assessments;
CREATE POLICY "Manager view client diet map assessments"
  ON public.diet_map_assessments FOR SELECT
  USING (public.diet_map_is_my_client(user_id, auth.uid()));

DROP POLICY IF EXISTS "Admin view all diet map assessments" ON public.diet_map_assessments;
CREATE POLICY "Admin view all diet map assessments"
  ON public.diet_map_assessments FOR SELECT
  USING (public.is_admin(auth.uid()));

-- 商户端邀请：复用既有 notifications 通道，尊重客户的通知开关
CREATE OR REPLACE FUNCTION public.send_diet_map_invite(
  p_client_user_ids uuid[],
  p_template_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_client uuid;
  v_ids uuid[];
  v_title text;
  v_notify boolean;
  v_sent int := 0;
  v_skipped int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '仅健康管理师可发送邀请' USING ERRCODE = '42501';
  END IF;

  SELECT t.title INTO v_title
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.status = 'published'
     AND (p_template_id IS NULL OR t.id = p_template_id)
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF v_title IS NULL THEN
    RAISE EXCEPTION '本店尚未开放健康饮食导图，无法发送邀请' USING ERRCODE = '42501';
  END IF;

  IF p_client_user_ids IS NULL OR COALESCE(array_length(p_client_user_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION '请先选择至少一位客户' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(array_length(p_client_user_ids, 1), 0) > 100 THEN
    RAISE EXCEPTION '单次最多可邀请 100 位客户' USING ERRCODE = '22023';
  END IF;

  SELECT ARRAY(SELECT DISTINCT x FROM unnest(p_client_user_ids) x WHERE x IS NOT NULL)
    INTO v_ids;

  FOREACH v_client IN ARRAY v_ids LOOP
    IF NOT public.diet_map_is_my_client(v_client, v_uid) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT COALESCE((notification_settings ->> 'health')::boolean, true)
      INTO v_notify
      FROM public.profiles WHERE id = v_client;

    IF v_notify IS NOT TRUE THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_client,
      'diet_map_invite',
      '邀请你生成健康饮食导图',
      COALESCE(NULLIF(btrim(v_title), ''), '健康饮食导图') || '：花几分钟完成自测，就能生成属于你的饮食导图。',
      jsonb_build_object('template_id', p_template_id, 'from_manager_id', v_uid)
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN jsonb_build_object('sent', v_sent, 'skipped', v_skipped);
END;
$$;

REVOKE ALL ON FUNCTION public.diet_map_is_my_client(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_diet_map_invite(uuid[], uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.diet_map_is_my_client(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_diet_map_invite(uuid[], uuid) TO authenticated;