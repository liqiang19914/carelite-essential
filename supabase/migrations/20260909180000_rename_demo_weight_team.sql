-- 将固定演示企业改为专业体重管理团队命名；不影响其他企业。
DO $demo$
DECLARE
  v_root CONSTANT uuid := '9d20bc6b-cbd4-4153-84e5-01e5b58f041f';
  v_enterprise CONSTANT uuid := 'eb7e71d1-e2c1-4d75-87a8-d33f69b526fe';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.enterprises
    WHERE id = v_enterprise AND owner_profile_id = v_root
  ) THEN
    RAISE EXCEPTION '演示企业身份校验失败，已停止改名';
  END IF;

  UPDATE public.enterprises
     SET name = '轻盈体重管理工作室', updated_at = now()
   WHERE id = v_enterprise;

  UPDATE public.profiles p
     SET nickname = n.nickname, updated_at = now()
    FROM (VALUES
      (v_root, '轻盈体重管理工作室'),
      ('97be8cc0-45cc-420f-ba8f-5df7a2b02f4f'::uuid, '林舒然｜营养顾问'),
      ('aaf34d8b-4746-476c-aef1-9d27ac31975f'::uuid, '顾言川｜数据分析师'),
      ('1d6fe4ae-33e0-4a24-b41f-d8dbfe29ed2a'::uuid, '周以安｜运动教练'),
      ('3c5eca26-eb14-4318-897c-d4dcfc5b6e77'::uuid, '沈知夏｜行为教练')
    ) AS n(id, nickname)
   WHERE p.id = n.id AND p.enterprise_id = v_enterprise;

  UPDATE public.managers
     SET company_name = '轻盈体重管理工作室',
         intro_company = '轻盈体重管理工作室以饮食、运动、行为和数据复盘为核心，为不同阶段客户提供可持续的体重管理支持。',
         updated_at = now()
   WHERE id IN (
     v_root,
     '97be8cc0-45cc-420f-ba8f-5df7a2b02f4f'::uuid,
     'aaf34d8b-4746-476c-aef1-9d27ac31975f'::uuid,
     '1d6fe4ae-33e0-4a24-b41f-d8dbfe29ed2a'::uuid,
     '3c5eca26-eb14-4318-897c-d4dcfc5b6e77'::uuid
   ) AND public.get_profile_enterprise_id(id) = v_enterprise;

  UPDATE public.health_manager_agents a
     SET config = COALESCE(a.config, '{}'::jsonb) || jsonb_build_object(
           'company_name', '轻盈体重管理工作室',
           'intro_company', '轻盈体重管理工作室以饮食、运动、行为和数据复盘为核心，为不同阶段客户提供可持续的体重管理支持。'
         ),
         updated_at = now()
   WHERE a.enterprise_id = v_enterprise AND a.is_active;

  UPDATE public.merchant_wecom_settings
     SET welcome_message = '欢迎加入轻盈体重管理工作室。请先发送身高、当前体重、目标体重和日常作息，健康管理师会结合你的情况给出建议。',
         updated_at = now()
   WHERE root_manager_id = v_root;
END
$demo$;
