-- Phase 2: 多图报告支持 —— 一份报告可对应多张图片（逐页拍照场景）
ALTER TABLE public.medical_reports
  ADD COLUMN IF NOT EXISTS file_urls jsonb;

-- 历史数据回填：file_urls = [file_url]（仅对图片类型且为空的行）
UPDATE public.medical_reports
SET file_urls = jsonb_build_array(file_url)
WHERE file_urls IS NULL
  AND file_url IS NOT NULL
  AND file_type IN ('jpg','jpeg','png','webp','gif','bmp');
