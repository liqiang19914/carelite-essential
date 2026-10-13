-- ① 模板加企业归属：root_manager_id 为空＝平台参考版，非空＝该企业自己的版本；
--    source_template_id 记录它是从哪份参考版复制来的。
ALTER TABLE public.diet_map_templates
  ADD COLUMN IF NOT EXISTS root_manager_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS source_template_id uuid REFERENCES public.diet_map_templates(id) ON DELETE SET NULL;

-- map_key 由全局唯一改为「仅参考版唯一」：商户副本沿用同一个 map_key，
-- 否则一复制就撞唯一索引。商户侧改用「每份参考版最多一份副本」来防重。
DROP INDEX IF EXISTS public.diet_map_templates_map_key_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_diet_map_templates_reference_key
  ON public.diet_map_templates (map_key)
  WHERE root_manager_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_diet_map_templates_merchant_copy
  ON public.diet_map_templates (root_manager_id, source_template_id)
  WHERE root_manager_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_diet_map_templates_root
  ON public.diet_map_templates (root_manager_id, status);

-- ② 评估记录盖企业章：同一份档案跨商户答题时按企业隔离历史。
ALTER TABLE public.diet_map_assessments
  ADD COLUMN IF NOT EXISTS root_manager_id uuid;

-- 存量回填：快照里本来就写了 root_manager_id，没有的再按提交时的管理师换算企业根。
UPDATE public.diet_map_assessments a
   SET root_manager_id = COALESCE(
         NULLIF(btrim(COALESCE(a.report_snapshot ->> 'root_manager_id', '')), '')::uuid,
         public.get_enterprise_root_manager_id(a.manager_id)
       )
 WHERE a.root_manager_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_diet_map_assessments_root_time
  ON public.diet_map_assessments (root_manager_id, submitted_at DESC, id DESC);

-- ③ 谁能改哪份模板：平台管理员可改全部；企业主/企业管理员只能改本企业那一份。
CREATE OR REPLACE FUNCTION public.diet_map_can_manage_template(p_template_id uuid, p_uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_uid IS NULL THEN false
    WHEN public.is_admin(p_uid) THEN true
    ELSE EXISTS (
      SELECT 1
        FROM public.diet_map_templates t
       WHERE t.id = p_template_id
         AND t.root_manager_id IS NOT NULL
         AND public.is_enterprise_admin(p_uid)
         AND t.root_manager_id = public.get_enterprise_root_manager_id(p_uid)
    )
  END;
$function$;

-- 商户端配置页直接读写自己那一份模板行，所以要放行 SELECT / UPDATE。
-- 新建副本只走下面的 SECURITY DEFINER 接口，不给商户 INSERT / DELETE。
DROP POLICY IF EXISTS "Enterprise admin view own diet map template" ON public.diet_map_templates;
CREATE POLICY "Enterprise admin view own diet map template"
  ON public.diet_map_templates FOR SELECT
  USING (
    root_manager_id IS NOT NULL
    AND public.is_enterprise_admin(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  );

DROP POLICY IF EXISTS "Enterprise admin update own diet map template" ON public.diet_map_templates;
CREATE POLICY "Enterprise admin update own diet map template"
  ON public.diet_map_templates FOR UPDATE
  USING (
    root_manager_id IS NOT NULL
    AND public.is_enterprise_admin(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  )
  WITH CHECK (
    root_manager_id IS NOT NULL
    AND public.is_enterprise_admin(auth.uid())
    AND root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
  );