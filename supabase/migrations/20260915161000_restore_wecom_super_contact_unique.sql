-- 好友同步使用 ON CONFLICT (root_manager_id, external_userid)，正式库需有匹配的唯一索引。
CREATE UNIQUE INDEX IF NOT EXISTS uq_wecom_super_contact
  ON public.wecom_super_contacts (root_manager_id, external_userid);
