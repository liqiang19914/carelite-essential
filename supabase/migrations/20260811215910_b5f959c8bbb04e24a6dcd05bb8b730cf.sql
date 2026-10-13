-- 商户章：这条测量是在哪家商户的应用里产生的。
-- 可为空 —— 老小程序包还在微信审核队列里，它们上传的数据暂时没有章，只归平台可见，不能因此报错。
ALTER TABLE public.measure_tickets
  ADD COLUMN IF NOT EXISTS oem_manager_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.body_compositions
  ADD COLUMN IF NOT EXISTS oem_manager_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_body_compositions_oem_manager
  ON public.body_compositions (oem_manager_id, record_id, measured_at DESC)
  WHERE oem_manager_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_measure_tickets_oem_manager
  ON public.measure_tickets (oem_manager_id)
  WHERE oem_manager_id IS NOT NULL;