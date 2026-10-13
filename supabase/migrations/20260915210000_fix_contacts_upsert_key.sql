-- ============================================================================
-- 紧急修复：wecom_super_contacts 的唯一约束漏了 device_guid
--
-- 原约束 uq_wecom_super_contact (root_manager_id, external_userid) 导致：
--   1) 多外挂设备同步同一位客户时，UPSERT 会互相覆盖 device_guid（谁最后同步谁赢）
--   2) 最终只有一台设备上保留该好友行，跨设备共加无法识别
--
-- 新约束改为 (root_manager_id, device_guid, external_userid)
-- → 每个设备独立维护好友；同客户被多外挂加，就会有多行映射、profileCoHosts 聚合命中
-- ============================================================================

ALTER TABLE public.wecom_super_contacts
  DROP CONSTRAINT IF EXISTS uq_wecom_super_contact;

ALTER TABLE public.wecom_super_contacts
  ADD CONSTRAINT uq_wecom_super_contact
  UNIQUE (root_manager_id, device_guid, external_userid);

-- 单独加一个 (root, external_userid) 方便跨设备找「同一 external_userid 被几台设备见过」
CREATE INDEX IF NOT EXISTS idx_wecom_super_contacts_root_ext
  ON public.wecom_super_contacts (root_manager_id, external_userid);
