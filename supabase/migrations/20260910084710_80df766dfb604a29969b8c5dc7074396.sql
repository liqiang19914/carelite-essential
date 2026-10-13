-- 审查修复（464/465/466）：企微客户库 Realtime 广播改私有频道 + 订阅策略
-- 原 notify_wecom_contact_change 第 4 参 false=公开频道，任何拿到 anon key 的客户端都能订阅任意商户频道。
-- 改为 true（私有频道），并由 realtime.messages 的 RLS 订阅策略按企业根收口：仅该企业根下的成员
-- （企业主 parent_manager_id 为空取本人、员工 parent_manager_id=根 id，COALESCE 口径与 root 口径 parent_manager_id||id 一致）
-- 能订阅本企业频道。语义字段变化判定与「updated_at 不参与判定」的刻意取舍原样保留（防 17000+ 批量重同步事件风暴）。

CREATE OR REPLACE FUNCTION public.notify_wecom_contact_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_external_userid text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_root := OLD.root_manager_id;
    v_external_userid := OLD.external_userid;
  ELSE
    v_root := NEW.root_manager_id;
    v_external_userid := NEW.external_userid;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.name IS NOT DISTINCT FROM OLD.name
       AND NEW.avatar_url IS NOT DISTINCT FROM OLD.avatar_url
       AND NEW.follow_userids IS NOT DISTINCT FROM OLD.follow_userids
       AND NEW.profile_id IS NOT DISTINCT FROM OLD.profile_id
       AND NEW.lost_at IS NOT DISTINCT FROM OLD.lost_at THEN
      RETURN NULL;
    END IF;
  END IF;

  PERFORM realtime.send(
    jsonb_build_object('external_userid', v_external_userid),
    'contact_update',
    'wecom-pro-contact:' || v_root::text,
    true
  );

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.notify_wecom_contact_change() FROM PUBLIC, anon, authenticated;

-- 私有频道的订阅策略：realtime.messages 的 SELECT 策略决定谁能订阅某频道。
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wecom_pro_contact_subscribe ON realtime.messages;
CREATE POLICY wecom_pro_contact_subscribe
ON realtime.messages FOR SELECT TO authenticated
USING (
  realtime.topic() = 'wecom-pro-contact:' || (
    SELECT COALESCE(p.parent_manager_id, p.id)::text
    FROM public.profiles p
    WHERE p.id = auth.uid()
  )
);