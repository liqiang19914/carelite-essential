-- feature 472: 分享出去的称重报告公开页与 App 内按秤来源显示保持一致。
-- 只做一件事：在分享展示数据包的白名单里补上 providerKey（粗粒度秤品牌标识），
-- 使公开页能吃到 App 内既有的两条显示规则（有品 picooc_scale 隐藏心率/心脏指数/骨骼肌率/皮下脂肪四行、
-- 肌肉量按「体重×肌肉率」展示层推算）。其余白名单键与取值逐字保持线上现状。
-- 注意：providerKey 只是秤品牌 token（picooc_scale / yolanda_scale / manual_demo / manual / imported），
-- 仍不含 device_ref、内部 id、record_id、notes、oem_manager_id，符合 feature 398「不外送设备引用」的边界。
-- 纯幂等 CREATE OR REPLACE，可安全重放。

CREATE OR REPLACE FUNCTION public.share_measure_package(
  p_row public.body_compositions,
  p_member_name text,
  p_gender text,
  p_height_cm numeric,
  p_age_at_measure integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $function$
BEGIN
  RETURN jsonb_build_object(
    'memberName', p_member_name,
    'gender', CASE WHEN p_gender IN ('male', '男') THEN 'male'
                   WHEN p_gender IN ('female', '女') THEN 'female'
                   ELSE NULL END,
    'heightCm', p_height_cm,
    'ageAtMeasure', p_age_at_measure,
    'measuredAt', p_row.measured_at,
    'origin', p_row.origin,
    'providerKey', p_row.provider_key,
    'weight', p_row.weight,
    'heartRate', p_row.heart_rate,
    'heartIndex', p_row.heart_index,
    'bmi', p_row.bmi,
    'bodyFatPercent', p_row.body_fat_percent,
    'waterPercent', p_row.water_percent,
    'skeletalMusclePercent', p_row.skeletal_muscle_percent,
    'musclePercent', p_row.muscle_percent,
    'muscleMass', p_row.muscle_mass,
    'boneMass', p_row.bone_mass,
    'lbm', p_row.lbm,
    'proteinPercent', p_row.protein_percent,
    'subcutaneousFatPercent', p_row.subcutaneous_fat_percent,
    'visceralFatLevel', p_row.visceral_fat_level,
    'bodyAge', p_row.body_age,
    'bodyShape', p_row.body_shape,
    'bmr', p_row.bmr,
    'muscleStorageScore', p_row.muscle_storage_score,
    'healthScore', p_row.health_score,
    'metricsMeta', p_row.metrics_meta,
    'missingMetrics', p_row.missing_metrics
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.share_measure_package(public.body_compositions, text, text, numeric, integer) FROM PUBLIC;

COMMENT ON FUNCTION public.share_measure_package(public.body_compositions, text, text, numeric, integer) IS
  '把一条体成分测量组装成分享公开页的展示数据包。纯转换函数：只吃传入值，白名单收口展示字段，绝不返回内部 id / 设备引用 / 备注。自 feature 472 起白名单新增 providerKey（粗粒度秤品牌标识，如 picooc_scale / yolanda_scale / manual_demo / manual / imported），供公开页与 App 内保持同一套按秤显示规则；边界不变：device_ref、id、record_id、notes、oem_manager_id 仍不外送。';

COMMENT ON FUNCTION public.get_public_health_share(text) IS
  '免登录读取分享数据包。token 不存在、来源已删除（外键 CASCADE 带走分享行）或对比缺一条时统一返回 status=invalid，不泄露存在性。只返回展示白名单字段：无 user_id / record_id / 内部 UUID / 设备引用 / 备注；档案参数只给性别、身高与测量当天年龄，不给出生日期。品牌按 root_manager_id 解析，查不到一律降级平台品牌而不报错。weighing 与 compare 两分支均经 public.share_measure_package 组装，自 feature 472 起两分支的每条测量都带 providerKey（粗粒度秤品牌标识，非设备引用）。';