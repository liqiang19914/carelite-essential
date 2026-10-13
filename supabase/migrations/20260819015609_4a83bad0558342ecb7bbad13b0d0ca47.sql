-- 进店即成商城会员（feature 188）
-- 会员是独立表 shop_members，与客户归属 client_relations 完全解耦：
-- 「进店即会员」不等于「成为商户客户」，登记本身绝不碰 client_relations，
-- 因此套餐客户数限额（挂在 client_relations 的触发器）拦截时也回滚不了会员登记。

-- ── 会员登记表 ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shop_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  client_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  member_sequence bigint NOT NULL CHECK (member_sequence > 0),
  member_number text NOT NULL CHECK (length(member_number) BETWEEN 3 AND 40),
  first_entered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  registration_source text NOT NULL DEFAULT 'entry'
    CHECK (registration_source IN ('entry', 'client_relation_backfill')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT shop_members_root_client_key UNIQUE (root_manager_id, client_id),
  CONSTRAINT shop_members_root_sequence_key UNIQUE (root_manager_id, member_sequence),
  CONSTRAINT shop_members_root_number_key UNIQUE (root_manager_id, member_number)
);

-- 每店自己的编号序号计数器（原子递增；序号允许有空洞，不允许重复）
CREATE TABLE IF NOT EXISTS public.shop_member_counters (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  last_value bigint NOT NULL CHECK (last_value >= 0)
);

CREATE INDEX IF NOT EXISTS shop_members_root_first_entered_idx
  ON public.shop_members (root_manager_id, first_entered_at DESC);
CREATE INDEX IF NOT EXISTS shop_members_client_first_entered_idx
  ON public.shop_members (client_id, first_entered_at);

ALTER TABLE public.shop_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_member_counters ENABLE ROW LEVEL SECURITY;

-- 客户读自己的会员记录
DROP POLICY IF EXISTS shop_members_select_self ON public.shop_members;
CREATE POLICY shop_members_select_self
  ON public.shop_members FOR SELECT TO authenticated
  USING (client_id = auth.uid());

-- 商户员工读本企业根的会员（跨商城互不可见：root 由服务端按登录人解析）
DROP POLICY IF EXISTS shop_members_select_enterprise ON public.shop_members;
CREATE POLICY shop_members_select_enterprise
  ON public.shop_members FOR SELECT TO authenticated
  USING (
    public.is_active_enterprise_content_member(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  );

-- 平台管理员全量读
DROP POLICY IF EXISTS shop_members_select_admin ON public.shop_members;
CREATE POLICY shop_members_select_admin
  ON public.shop_members FOR SELECT TO authenticated
  USING (public.is_admin(auth.uid()));

-- 客户端不能直接写会员表/计数器：一律走 SECURITY DEFINER RPC
GRANT SELECT ON public.shop_members TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.shop_members FROM anon, authenticated;
REVOKE ALL ON public.shop_member_counters FROM anon, authenticated;

-- ── 会员编号前缀：brand_slug → short_code → 根 UUID 前 4 位，固化进 member_number ──
CREATE OR REPLACE FUNCTION public.shop_member_prefix(p_root_manager_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_slug text;
  v_code text;
  v_prefix text;
BEGIN
  SELECT brand_slug, short_code INTO v_slug, v_code
  FROM public.managers WHERE id = p_root_manager_id;
  v_prefix := upper(regexp_replace(COALESCE(NULLIF(btrim(v_slug), ''), NULLIF(btrim(v_code), '')), '[^A-Za-z0-9]', '', 'g'));
  IF v_prefix IS NULL OR v_prefix = '' THEN
    v_prefix := upper(substr(replace(p_root_manager_id::text, '-', ''), 1, 4));
  END IF;
  RETURN v_prefix;
END;
$function$;

-- ── 自动登记接口：登录后首次进店登记，幂等，重复进店/并发都只留一条 ──
CREATE OR REPLACE FUNCTION public.register_shop_member(p_root_manager_id uuid)
RETURNS TABLE (member_id uuid, member_number text, first_entered_at timestamptz, created boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_sequence bigint;
  v_prefix text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  -- 只有客户角色的未禁用账号能登记商城会员（管理师/管理员不该被登记成"会员"）
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_uid AND role::text = 'user' AND COALESCE(is_disabled, false) = false
  ) THEN
    RAISE EXCEPTION '当前账号不能登记商城会员' USING ERRCODE = '42501';
  END IF;

  -- 必须是合法的公开内容根商户
  IF public.get_enterprise_root_manager_id(p_root_manager_id) IS DISTINCT FROM p_root_manager_id
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RAISE EXCEPTION '商城不存在或已停用' USING ERRCODE = '22023';
  END IF;

  -- 已登记过：直接返回现有记录（首次进店时间绝不覆盖）
  RETURN QUERY
  SELECT sm.id, sm.member_number, sm.first_entered_at, false
  FROM public.shop_members sm
  WHERE sm.root_manager_id = p_root_manager_id AND sm.client_id = v_uid;
  IF FOUND THEN RETURN; END IF;

  -- 原子递增该店序号（行锁保证并发下序号不重复；可能因后续冲突产生空号，允许）
  INSERT INTO public.shop_member_counters(root_manager_id, last_value)
  VALUES (p_root_manager_id, 1)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET last_value = public.shop_member_counters.last_value + 1
  RETURNING last_value INTO v_sequence;

  v_prefix := public.shop_member_prefix(p_root_manager_id);

  RETURN QUERY
  INSERT INTO public.shop_members(root_manager_id, client_id, member_sequence, member_number)
  VALUES (p_root_manager_id, v_uid, v_sequence, v_prefix || '-' || lpad(v_sequence::text, 6, '0'))
  ON CONFLICT (root_manager_id, client_id) DO NOTHING
  RETURNING shop_members.id, shop_members.member_number, shop_members.first_entered_at, true;

  -- 并发下另一条先到了：返回胜出那条
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT sm.id, sm.member_number, sm.first_entered_at, false
    FROM public.shop_members sm
    WHERE sm.root_manager_id = p_root_manager_id AND sm.client_id = v_uid;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.register_shop_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_shop_member(uuid) TO authenticated;

-- ── 存量回填：把现有 client_relations 归一到企业根后按 (root, client) 回填成会员 ──
-- 首次进店时间取该客户在该店最早的关联 created_at；编号按进店早晚排序分配。
WITH source AS (
  SELECT
    public.get_enterprise_root_manager_id(cr.manager_id) AS root_manager_id,
    cr.client_id,
    min(cr.created_at) AS first_entered_at
  FROM public.client_relations cr
  GROUP BY 1, cr.client_id
),
valid_source AS (
  SELECT s.* FROM source s
  WHERE s.root_manager_id IS NOT NULL
    AND public.is_public_enterprise_content_root(s.root_manager_id)
),
numbered AS (
  SELECT
    vs.*,
    row_number() OVER (PARTITION BY root_manager_id ORDER BY first_entered_at, client_id)::bigint AS member_sequence
  FROM valid_source vs
)
INSERT INTO public.shop_members(root_manager_id, client_id, member_sequence, member_number, first_entered_at, registration_source)
SELECT
  n.root_manager_id,
  n.client_id,
  n.member_sequence,
  public.shop_member_prefix(n.root_manager_id) || '-' || lpad(n.member_sequence::text, 6, '0'),
  n.first_entered_at,
  'client_relation_backfill'
FROM numbered n
ON CONFLICT (root_manager_id, client_id) DO NOTHING;

-- 校准计数器：每店 last_value 至少等于店内已分配的最大序号，避免与回填编号撞车
INSERT INTO public.shop_member_counters(root_manager_id, last_value)
SELECT root_manager_id, max(member_sequence)
FROM public.shop_members
GROUP BY root_manager_id
ON CONFLICT (root_manager_id) DO UPDATE
  SET last_value = GREATEST(public.shop_member_counters.last_value, EXCLUDED.last_value);