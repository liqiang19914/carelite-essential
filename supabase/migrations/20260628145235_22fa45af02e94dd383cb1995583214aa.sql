-- ============================================================
-- 管理师邀请注册制 + 后台审核 + 公开问答自动绑定
-- ============================================================

-- ---------- 1) managers 审核审计字段 ----------
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS submitted_at  timestamptz,
  ADD COLUMN IF NOT EXISTS reviewed_at   timestamptz,
  ADD COLUMN IF NOT EXISTS reviewed_by   uuid,
  ADD COLUMN IF NOT EXISTS review_note   text NOT NULL DEFAULT '';

-- ---------- 2) 历史管理师全部豁免为 approved（避免新审核门把现有管理师挡在门外）----------
UPDATE public.managers
   SET certification_status = 'approved'
 WHERE certification_status IS DISTINCT FROM 'approved';

-- ---------- 3) 收紧 certification_status 取值 ----------
ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_certification_status_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_certification_status_check
  CHECK (certification_status IN ('pending','approved','rejected'));

-- ---------- 4) 注册邀请表 ----------
CREATE TABLE IF NOT EXISTS public.manager_registration_invites (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token       uuid NOT NULL DEFAULT gen_random_uuid(),
  label       text NOT NULL DEFAULT '',
  expires_at  timestamptz,
  max_uses    integer NOT NULL DEFAULT 1,
  used_count  integer NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS manager_registration_invites_token_key
  ON public.manager_registration_invites (token);
ALTER TABLE public.manager_registration_invites ENABLE ROW LEVEL SECURITY;

-- ---------- 5) 注册尝试表（限流）----------
CREATE TABLE IF NOT EXISTS public.manager_registration_attempts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token       uuid,
  phone       text,
  ip_hash     text,
  success     boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_mr_attempts_ip    ON public.manager_registration_attempts (ip_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mr_attempts_phone ON public.manager_registration_attempts (phone, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mr_attempts_token ON public.manager_registration_attempts (token, created_at DESC);
ALTER TABLE public.manager_registration_attempts ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- RPC: admin 创建/列出/撤销注册邀请
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_registration_invite(
  p_label text DEFAULT '',
  p_expires_at timestamptz DEFAULT NULL,
  p_max_uses integer DEFAULT 1
) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_row public.manager_registration_invites;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;
  IF COALESCE(p_max_uses, 0) < 1 OR p_max_uses > 1000 THEN
    RAISE EXCEPTION 'max_uses 必须在 1~1000 之间';
  END IF;
  INSERT INTO public.manager_registration_invites (label, expires_at, max_uses, created_by)
  VALUES (COALESCE(btrim(p_label), ''), p_expires_at, p_max_uses, auth.uid())
  RETURNING * INTO v_row;
  RETURN to_json(v_row);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_create_registration_invite(text, timestamptz, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_list_registration_invites()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_json json;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;
  SELECT COALESCE(json_agg(t ORDER BY t.created_at DESC), '[]'::json) INTO v_json
  FROM (
    SELECT id, token, label, expires_at, max_uses, used_count, is_active, created_at
    FROM public.manager_registration_invites
    ORDER BY created_at DESC
    LIMIT 200
  ) t;
  RETURN v_json;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_list_registration_invites() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_revoke_registration_invite(p_token uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_row public.manager_registration_invites;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;
  UPDATE public.manager_registration_invites
     SET is_active = false
   WHERE token = p_token
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION '邀请不存在';
  END IF;
  RETURN to_json(v_row);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_revoke_registration_invite(uuid) TO authenticated;

-- ============================================================
-- RPC: admin 审核管理师
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_review_manager(
  p_manager_id uuid,
  p_action text,
  p_note text DEFAULT ''
) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_trimmed text;
  v_status text;
  v_note text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;
  IF p_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'invalid action: %', p_action;
  END IF;
  v_trimmed := btrim(COALESCE(p_note, ''));
  IF p_action = 'reject' AND v_trimmed = '' THEN
    RAISE EXCEPTION 'rejection requires a non-empty note';
  END IF;
  IF char_length(v_trimmed) > 500 THEN
    RAISE EXCEPTION 'review_note too long (max 500)';
  END IF;

  UPDATE public.managers
     SET certification_status = CASE WHEN p_action = 'approve' THEN 'approved' ELSE 'rejected' END,
         reviewed_at = NOW(),
         reviewed_by = auth.uid(),
         review_note = CASE WHEN p_action = 'reject' THEN v_trimmed ELSE '' END,
         updated_at = NOW()
   WHERE id = p_manager_id
  RETURNING certification_status, review_note INTO v_status, v_note;

  IF NOT FOUND THEN
    RAISE EXCEPTION '管理师不存在';
  END IF;

  RETURN json_build_object('success', true, 'manager_id', p_manager_id, 'status', v_status, 'review_note', v_note);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_review_manager(uuid, text, text) TO authenticated;

-- ============================================================
-- RPC: 管理师自查状态（子账号 fail-open）
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_manager_status()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.managers%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_row FROM public.managers WHERE id = v_uid;
  IF NOT FOUND THEN
    -- 子账号（manage-sub-account 创建，仅 profiles.role='manager'，无 managers 行）放行
    RETURN json_build_object(
      'status', 'approved',
      'has_record', false,
      'review_note', '',
      'submitted_at', NULL,
      'reviewed_at', NULL
    );
  END IF;

  RETURN json_build_object(
    'status', v_row.certification_status,
    'has_record', true,
    'review_note', COALESCE(v_row.review_note, ''),
    'submitted_at', v_row.submitted_at,
    'reviewed_at', v_row.reviewed_at
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_my_manager_status() TO authenticated;

-- ============================================================
-- RPC: 被驳回管理师重新提交审核
-- ============================================================
CREATE OR REPLACE FUNCTION public.resubmit_my_manager_registration()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  UPDATE public.managers
     SET certification_status = 'pending',
         submitted_at = NOW(),
         review_note = '',
         reviewed_at = NULL,
         reviewed_by = NULL,
         updated_at = NOW()
   WHERE id = v_uid
     AND certification_status = 'rejected'
  RETURNING certification_status INTO v_status;
  IF NOT FOUND THEN
    RAISE EXCEPTION '当前状态不可重新提交审核';
  END IF;
  RETURN json_build_object('success', true, 'status', v_status);
END;
$$;
GRANT EXECUTE ON FUNCTION public.resubmit_my_manager_registration() TO authenticated;

-- ============================================================
-- RPC: 公开问答页自动绑定（无邀请码、强登录后）
-- ============================================================
CREATE OR REPLACE FUNCTION public.bind_manager_from_public(p_manager_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_manager public.managers%ROWTYPE;
  v_role text;
  v_relation_id uuid;
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

  -- 仅普通用户可被绑定为客户（管理师/管理员访问公开页不绑定）
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

  -- 防并发：对同一 client 上事务级 advisory 锁
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text, 11));

  -- 自动切换：停用该用户其它所有 active 绑定
  UPDATE public.client_relations
     SET status = 'inactive', updated_at = NOW()
   WHERE client_id = v_uid AND manager_id <> p_manager_id AND status = 'active';

  SELECT id INTO v_relation_id
  FROM public.client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    INSERT INTO public.client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (p_manager_id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE public.client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object('success', true, 'reason', 'bound', 'manager_id', p_manager_id, 'relation_id', v_relation_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.bind_manager_from_public(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_public(uuid) TO authenticated;