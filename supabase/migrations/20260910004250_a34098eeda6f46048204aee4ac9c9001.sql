-- feature 466：企微外部联系人 ↔ 小程序用户按 unionID 自动关联
-- 关联函数：给定 profile，把同企业根、unionid 相等且尚未关联的联系人回链到该 profile。
CREATE OR REPLACE FUNCTION public.link_wecom_contacts_by_unionid(p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_unionid text;
  v_root uuid;
BEGIN
  SELECT p.wechat_unionid, COALESCE(p.parent_manager_id, p.id)
    INTO v_unionid, v_root
    FROM public.profiles p
    WHERE p.id = p_profile_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF v_unionid IS NULL OR v_unionid = '' THEN
    RETURN;
  END IF;

  UPDATE public.merchant_wecom_contacts c
     SET profile_id = p_profile_id
   WHERE c.root_manager_id = v_root
     AND c.type = 'contact'
     AND c.profile_id IS NULL
     AND COALESCE(c.unionid, '') = v_unionid;
END;
$function$;

REVOKE ALL ON FUNCTION public.link_wecom_contacts_by_unionid(uuid) FROM PUBLIC, anon, authenticated;

-- 触发器函数：profiles 写入非空 wechat_unionid 时调用关联函数回链。
-- SECURITY DEFINER 必须：关联函数已收紧 EXECUTE 权限，只有函数属主能调用它。
CREATE OR REPLACE FUNCTION public.trg_link_wecom_contacts_by_unionid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  PERFORM public.link_wecom_contacts_by_unionid(NEW.id);
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.trg_link_wecom_contacts_by_unionid() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_profiles_wechat_unionid_link ON public.profiles;
CREATE TRIGGER trg_profiles_wechat_unionid_link
AFTER INSERT OR UPDATE OF wechat_unionid ON public.profiles
FOR EACH ROW
WHEN (NEW.wechat_unionid IS NOT NULL AND NEW.wechat_unionid <> '')
EXECUTE FUNCTION public.trg_link_wecom_contacts_by_unionid();