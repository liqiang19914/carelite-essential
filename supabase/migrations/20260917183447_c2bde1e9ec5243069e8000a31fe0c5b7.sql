-- 商品 AI 摘要缓存（feature 470 修复批）：空结果需两次独立尝试才当「图内无文字」
-- 新增待确认空白记数：image_blanks = { 详情图URL: 连续空结果次数 }。
-- 读路径把仅出现在这里的 URL 当缺失（下一轮重试）；第二次仍空才写进 image_texts 的空串。
ALTER TABLE public.product_ai_summaries
  ADD COLUMN IF NOT EXISTS image_blanks jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.product_ai_summaries.image_blanks IS
  '空结果但尚未确认的详情图：URL → 连续空白次数（达到 2 次才写进 image_texts 的空串）';
