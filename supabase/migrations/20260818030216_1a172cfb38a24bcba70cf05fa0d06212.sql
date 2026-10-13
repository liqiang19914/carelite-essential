-- 商户自有协议正文 + 登录页文案（按企业根商户存一份，多员工入口共用）
-- 所有读写都走 SECURITY DEFINER RPC，表本身不对 anon / authenticated 开放直连。
CREATE TABLE IF NOT EXISTS public.merchant_brand_docs (
  root_manager_id     uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- 三份协议正文（Markdown 轻语法：## 小标题、- 列表、**加粗**）
  privacy_body        text,
  agreement_body      text,
  compliance_body     text,
  docs_updated_on     date,
  -- 登录页文案
  login_slogan        text,
  login_subtitle      text,
  login_new_user_tip  text,
  login_slides        jsonb,
  icp_record          text,
  app_version_label   text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid REFERENCES public.profiles(id) ON DELETE SET NULL
);

ALTER TABLE public.merchant_brand_docs ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.merchant_brand_docs IS
  '商户自有协议正文与登录页文案，按企业根商户 root_manager_id 存一份。只通过 get_my_merchant_brand_docs / save_my_merchant_brand_docs / get_public_merchant_brand_docs 访问。';