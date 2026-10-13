-- 历史测量补商户章。三级规则，按可信度从高到低，取第一个能确定的：
--   A. 导入数据：按导入当时给谁开的授权对齐（导入本来就指定了归属商户）
--   B. 这款秤全平台只有一家商户开通过，且客户在测量之前就已归属那家
--      —— 别家小程序包里根本没有这款秤的插件，测量不可能在别家产生
--   C. 按当时归属推断：测量时点之前最近建立的那条归属；若所有归属都建立在测量之后，
--      取最早那条（视为首次接触的商户）
-- 三级都定不下来的留空，只归平台可见，并在后台导出清单人工核对。
WITH cand AS (
  SELECT bc.id,
    COALESCE(
      CASE WHEN bc.origin = 'imported' THEN (
        SELECT ra.manager_id
        FROM public.record_authorizations ra
        JOIN public.client_relations cr ON cr.manager_id = ra.manager_id AND cr.client_id = hr.user_id
        WHERE ra.record_id = bc.record_id AND ra.is_active = true
        ORDER BY abs(extract(epoch FROM (ra.granted_at - bc.created_at))) ASC
        LIMIT 1
      ) END,
      (
        SELECT cr.manager_id
        FROM public.client_relations cr
        WHERE cr.client_id = hr.user_id
          AND cr.status = 'active'
          AND cr.created_at <= bc.measured_at
          AND EXISTS (
            SELECT 1 FROM public.oem_device_grants g
            WHERE g.manager_id = cr.manager_id
              AND g.provider_key = bc.provider_key
              AND g.grant_status = 'granted'
          )
          AND (
            SELECT count(DISTINCT g2.manager_id) FROM public.oem_device_grants g2
            WHERE g2.provider_key = bc.provider_key AND g2.grant_status = 'granted'
          ) = 1
        ORDER BY cr.created_at DESC
        LIMIT 1
      ),
      (
        SELECT cr.manager_id
        FROM public.client_relations cr
        WHERE cr.client_id = hr.user_id AND cr.status = 'active'
        ORDER BY (cr.created_at <= bc.measured_at) DESC,
                 CASE WHEN cr.created_at <= bc.measured_at THEN cr.created_at END DESC NULLS LAST,
                 cr.created_at ASC
        LIMIT 1
      )
    ) AS mid
  FROM public.body_compositions bc
  JOIN public.health_records hr ON hr.id = bc.record_id
  WHERE bc.oem_manager_id IS NULL
)
UPDATE public.body_compositions bc
SET oem_manager_id = c.mid
FROM cand c
WHERE c.id = bc.id AND c.mid IS NOT NULL;