-- 企微超级助手：小程序消息卡片模板库
-- 消息发送（手动聊天 / 私信群发 / 群群发）可携带一张小程序卡片，
-- 走 QiWe /msg/sendWeapp；卡片参数（appId/原始ID/页面路径/标题/描述/封面）沉淀为模板复用。
-- 封面图存 OSS 公网 URL，发送时 cron/EF 再用 /cloud/cdnBigUploadByUrl 换协议商凭证
-- （coverFileId/coverFileAesKey/coverFileSize），与图片附件同一套链路。

CREATE TABLE IF NOT EXISTS public.wecom_super_weapp_cards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  card_name text NOT NULL,                  -- 模板内部名称（仅商户自己看）
  app_id text NOT NULL,                     -- 小程序 appId，wx 开头
  username text NOT NULL,                   -- 小程序原始 ID，形如 gh_xxx@app
  page_path text NOT NULL DEFAULT '',       -- 小程序跳转页面路径
  title text NOT NULL DEFAULT '',           -- 卡片标题
  description text NOT NULL DEFAULT '',     -- 卡片描述
  cover_url text NOT NULL DEFAULT '',       -- 封面图公网 URL（OSS）
  cover_name text NOT NULL DEFAULT '',      -- 封面文件名
  cover_size bigint NOT NULL DEFAULT 0,     -- 封面字节数
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wecom_super_weapp_card_name_check CHECK (char_length(btrim(card_name)) BETWEEN 1 AND 100),
  CONSTRAINT wecom_super_weapp_appid_check CHECK (char_length(app_id) BETWEEN 6 AND 64),
  CONSTRAINT wecom_super_weapp_username_check CHECK (char_length(username) BETWEEN 6 AND 128),
  CONSTRAINT wecom_super_weapp_title_check CHECK (char_length(title) <= 64),
  CONSTRAINT wecom_super_weapp_desc_check CHECK (char_length(description) <= 120),
  CONSTRAINT wecom_super_weapp_page_check CHECK (char_length(page_path) <= 512)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_weapp_cards_root
  ON public.wecom_super_weapp_cards (root_manager_id, updated_at DESC);

ALTER TABLE public.wecom_super_weapp_cards ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_weapp_cards FROM anon, authenticated;
