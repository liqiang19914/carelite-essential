-- 商品详细描述改富文本（feature 191）
-- 新增 description_doc 存 Tiptap 富文本文档（JSON），description 保留为纯文本镜像
-- （AI 润色、搜索、老商品回退都继续用 description）。
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS description_doc jsonb NULL;

COMMENT ON COLUMN public.products.description_doc IS
  '商品详细描述的富文本文档（Tiptap JSON）。有值时客户端按富文本渲染；为空时回退渲染纯文本 description。description 始终是它的纯文本镜像，供 AI 润色与搜索用。';