-- ============================================================================
-- 企微超级助手：外挂好友「双重匹配」
--   ① pro_external_userid  → 真实企微外部联系人（merchant_wecom_contacts）
--   ② customer_profile_id  → 平台客户健康档案（profiles role=user，经 client_relations 归属）
-- 两者独立存在、可只绑其一；自动回复的客户档案/RAG 以 customer_profile_id 为最高优先。
-- ============================================================================

ALTER TABLE public.wecom_super_contact_mapping
  ADD COLUMN IF NOT EXISTS customer_profile_id uuid,
  ALTER COLUMN pro_external_userid DROP NOT NULL;

-- 同一外挂好友只能绑一个客户档案；同一客户档案可被多个外挂好友指向（不加唯一）
CREATE INDEX IF NOT EXISTS idx_super_contact_mapping_customer
  ON public.wecom_super_contact_mapping (root_manager_id, customer_profile_id);

-- 客户注销时自动解除映射，避免悬空
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_super_contact_mapping_customer'
  ) THEN
    ALTER TABLE public.wecom_super_contact_mapping
      ADD CONSTRAINT fk_super_contact_mapping_customer
      FOREIGN KEY (customer_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;
  END IF;
END $$;
