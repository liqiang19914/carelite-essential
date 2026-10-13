-- 商品详情「AI 可读摘要」缓存（feature 470）
-- 内容 = 副标题 + 商品介绍 + 详情文档文本块 + 详情图 OCR 文字 + 标签；不含价格/库存/活动价。
-- 只有问答 Edge Function（service_role）读写，前端角色一律拒绝：
-- RLS 已开且不建任何策略，这里再显式收回表级权限做双重保险。
CREATE TABLE IF NOT EXISTS public.product_ai_summaries (
  product_id uuid PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  fingerprint text NOT NULL DEFAULT '',
  summary text NOT NULL DEFAULT '',
  image_texts jsonb NOT NULL DEFAULT '{}'::jsonb,
  image_total integer NOT NULL DEFAULT 0,
  image_done integer NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'text_only',
  ocr_attempted_at timestamptz,
  built_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_ai_summaries_source_check
    CHECK (source IN ('text_only', 'ocr_partial', 'ocr_full'))
);

ALTER TABLE public.product_ai_summaries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.product_ai_summaries FROM anon, authenticated;

COMMENT ON TABLE public.product_ai_summaries IS '商品详情 AI 可读摘要缓存：指纹=源内容(标题/副标题/介绍/详情文档/图片清单/标签)哈希，不匹配即重建；仅云函数 service_role 读写';
COMMENT ON COLUMN public.product_ai_summaries.fingerprint IS '源内容指纹（sha256），与当前商品内容不一致即重建';
COMMENT ON COLUMN public.product_ai_summaries.summary IS '拼装后的可读摘要文本（不含价格/库存/活动价）';
COMMENT ON COLUMN public.product_ai_summaries.image_texts IS '详情图 URL → OCR 文字（按 URL 去重；空串=已识别但图内无文字；缺键=尚未识别成功）';
COMMENT ON COLUMN public.product_ai_summaries.image_total IS '当前详情图张数（受单商品上限约束）';
COMMENT ON COLUMN public.product_ai_summaries.image_done IS '已成功识别的详情图张数';
COMMENT ON COLUMN public.product_ai_summaries.source IS 'text_only=仅文字摘要 ocr_partial=部分详情图已识别 ocr_full=全部详情图已识别';
COMMENT ON COLUMN public.product_ai_summaries.ocr_attempted_at IS 'OCR 整轮零进展（一张都没成功）的时间，用于冷却窗口内不再重复调用';
