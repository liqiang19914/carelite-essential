-- merchant_wecom_chat_group_members 加 avatar_url 列
ALTER TABLE public.merchant_wecom_chat_group_members
ADD COLUMN IF NOT EXISTS avatar_url text;

COMMENT ON COLUMN public.merchant_wecom_chat_group_members.avatar_url IS '成员头像 URL（企业成员从 WeCom groupchat/get 返回，外部成员同步自 merchant_wecom_contacts）';
