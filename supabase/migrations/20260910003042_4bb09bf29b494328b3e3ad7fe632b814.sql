-- feature 465: 企微客户库实时更新
-- merchant_wecom_contacts 表对客户端不授权（无可用 SELECT 策略），postgres_changes 行变更
-- 订阅收不到加粉/删粉事件；沿用 338 口碑评论 notify_reputation_post_changed 同款模式：
-- 由数据库触发器在 AFTER INSERT/UPDATE/DELETE 时主动 realtime.send 最小载荷到
-- wecom-pro-contact:{企业根} 频道，客户库页据此自动失效 contacts/contact-stats/contact-detail/staff。
--
-- 触发频率与节流说明：
--   · INSERT（新好友/客服会话进入列表）与 DELETE（联系删除）必发——实时进入/移出是需求核心。
--   · UPDATE 只在影响客户库展示的语义字段（name/avatar_url/follow_userids/profile_id/lost_at）真正
--     变化时才广播，避免每次写入都刷新。面同步 EF 的 ON CONFLICT DO UPDATE 会对批内每行（即使数据没变）
--     执行一次 UPDATE 并 set updated_at=now()；若把 updated_at 纳入「有无变化」判定，一次 17000+ 行
--     全量重同步会对每行都形成一次广播、在 Realtime 层造成事件风暴。updated_at 只是簿记时间戳、
--     不是客户库可见字段，故不参与变化判定（与 338 的「只在语义字段变化时推送」口径一致）。
--   · 载荷最小化：频道名已携带企业根（root 在频道里），payload 只带 external_userid，不携带任何业务数值。
--   · Realtime 对窄带广播天然聚合；本函数不做额外限流，靠上面的变化判定消除批量重同步的冗余事件。

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
    false
  );

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_wecom_contact_change ON public.merchant_wecom_contacts;
CREATE TRIGGER trg_wecom_contact_change
AFTER INSERT OR UPDATE OR DELETE ON public.merchant_wecom_contacts
FOR EACH ROW EXECUTE FUNCTION public.notify_wecom_contact_change();

REVOKE ALL ON FUNCTION public.notify_wecom_contact_change() FROM PUBLIC, anon, authenticated;