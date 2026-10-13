-- AI 消息分享快照（豆包式：任何人拿到链接/卡片都能看完整对话摘要 + 海报）
-- 隐私：存的是"摘要"（snapshot_content）而非原始消息全文；默认 7 天过期，用户可撤销

DROP TABLE IF EXISTS public.ai_share_snapshots CASCADE;

CREATE TABLE public.ai_share_snapshots (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_token       uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  owner_user_id      uuid REFERENCES auth.users(id),
  manager_id         uuid,

  -- 消息来源定位（用于反查健管师 / 品牌信息）
  message_source     text NOT NULL CHECK (message_source IN ('conversations', 'public_qa', 'openclaw')),
  message_id         uuid NOT NULL,
  conversation_id    uuid,
  session_id         uuid,

  -- 冻结快照：存文案摘要（不是全文），防止原消息被改/删后分享页空白
  snapshot_content   text NOT NULL,
  snapshot_summary   text,

  -- 健管师/品牌名片快照（分享海报上用）
  manager_name       text,
  manager_avatar_url text,
  brand_name         text,
  brand_logo_url     text,

  -- 海报（可选：先生成快照再画海报，两步走）
  poster_url         text,

  -- 可见性
  expires_at         timestamptz NOT NULL DEFAULT now() + interval '7 days',
  is_revoked         boolean NOT NULL DEFAULT false,

  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ai_share_snapshots_token_idx ON public.ai_share_snapshots (public_token);
CREATE INDEX ai_share_snapshots_owner_idx  ON public.ai_share_snapshots (owner_user_id, created_at DESC);
CREATE INDEX ai_share_snapshots_msg_idx    ON public.ai_share_snapshots (message_source, message_id);

ALTER TABLE public.ai_share_snapshots ENABLE ROW LEVEL SECURITY;

-- 所有者：能插能改（补 poster_url、撤销）能看能删
CREATE POLICY ai_share_snapshots_owner_insert ON public.ai_share_snapshots
  FOR INSERT WITH CHECK (owner_user_id IS NULL OR owner_user_id = auth.uid());
CREATE POLICY ai_share_snapshots_owner_select ON public.ai_share_snapshots
  FOR SELECT USING (owner_user_id = auth.uid());
CREATE POLICY ai_share_snapshots_owner_update ON public.ai_share_snapshots
  FOR UPDATE USING (owner_user_id = auth.uid())
  WITH CHECK (owner_user_id = auth.uid());
CREATE POLICY ai_share_snapshots_owner_delete ON public.ai_share_snapshots
  FOR DELETE USING (owner_user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_share_snapshots TO authenticated;

-- ====================================================================
-- RPC 1：创建快照（返回 public_token）
-- ====================================================================
CREATE OR REPLACE FUNCTION public.create_share_snapshot(
  p_message_source   text,
  p_message_id       uuid,
  p_snapshot_content text,
  p_snapshot_summary text DEFAULT NULL,
  p_conversation_id  uuid DEFAULT NULL,
  p_session_id       uuid DEFAULT NULL,
  p_user_id          uuid DEFAULT NULL,
  p_expires_hours    int DEFAULT 168  -- 7 天
) RETURNS TABLE(
  id          uuid,
  public_token uuid,
  expires_at  timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_user_id    uuid := COALESCE(p_user_id, auth.uid());
  v_manager_id uuid;
  v_mgr_name   text;
  v_brand      text;
BEGIN
  -- 反查 manager（复用 feedback 表的思路 + 补 managers.brand_slug 取品牌名）
  IF p_message_source = 'conversations' AND p_conversation_id IS NOT NULL THEN
    SELECT c.owner_manager_id INTO v_manager_id
      FROM public.conversations c WHERE c.id = p_conversation_id;
  ELSIF p_message_source = 'public_qa' AND p_session_id IS NOT NULL THEN
    SELECT s.manager_id INTO v_manager_id
      FROM public.manager_public_qa_sessions s WHERE s.id = p_session_id;
  END IF;

  IF v_manager_id IS NOT NULL THEN
    SELECT m.partner_card_display_name, COALESCE(m.brand_slug, m.company_name, m.business_name)
      INTO v_mgr_name, v_brand
      FROM public.managers m WHERE m.id = v_manager_id;
  END IF;

  INSERT INTO public.ai_share_snapshots
    (owner_user_id, manager_id, message_source, message_id, conversation_id, session_id,
     snapshot_content, snapshot_summary, manager_name, brand_name, expires_at)
  VALUES
    (v_user_id, v_manager_id, p_message_source, p_message_id, p_conversation_id, p_session_id,
     p_snapshot_content, p_snapshot_summary, v_mgr_name, v_brand,
     now() + (p_expires_hours || ' hours')::interval)
  RETURNING ai_share_snapshots.id, ai_share_snapshots.public_token, ai_share_snapshots.expires_at;
END;
$$;

REVOKE ALL ON FUNCTION public.create_share_snapshot(text, uuid, text, text, uuid, uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_share_snapshot(text, uuid, text, text, uuid, uuid, uuid, int) TO authenticated, anon;

-- ====================================================================
-- RPC 2：公开查看（免登录）。验过期 + 撤销后返回 NULL
-- ====================================================================
CREATE OR REPLACE FUNCTION public.get_share_snapshot(p_public_token uuid)
RETURNS TABLE(
  id                uuid,
  snapshot_content  text,
  snapshot_summary  text,
  manager_name      text,
  manager_avatar_url text,
  brand_name        text,
  brand_logo_url    text,
  poster_url        text,
  created_at        timestamptz,
  expires_at        timestamptz,
  is_revoked        boolean
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
    SELECT s.id, s.snapshot_content, s.snapshot_summary,
           s.manager_name, s.manager_avatar_url, s.brand_name, s.brand_logo_url,
           s.poster_url, s.created_at, s.expires_at, s.is_revoked
      FROM public.ai_share_snapshots s
     WHERE s.public_token = p_public_token
       AND s.expires_at > now()
       AND NOT s.is_revoked;
END;
$$;

REVOKE ALL ON FUNCTION public.get_share_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_share_snapshot(uuid) TO authenticated, anon;

ALTER FUNCTION public.create_share_snapshot(text, uuid, text, text, uuid, uuid, uuid, int) SET search_path = public;
ALTER FUNCTION public.get_share_snapshot(uuid) SET search_path = public;
