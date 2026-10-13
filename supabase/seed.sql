-- ============================================================================
-- CareLite 演示数据（seed.sql）
-- ----------------------------------------------------------------------------
-- 1) 本地执行：`supabase db reset` 会在全部迁移完成后自动执行本文件。
-- 2) 云端执行：也可以在 Supabase SQL Editor 手动执行（先删后插，可重复执行）。
--
-- 演示账号清单（密码统一为 carelite123）：
--   ┌──────────┬─────────────────────────┬───────────────┬────────────────────────┐
--   │ 角色     │ 邮箱                    │ 手机号        │ 说明                   │
--   ├──────────┼─────────────────────────┼───────────────┼────────────────────────┤
--   │ admin    │ admin@carelite.local    │ 13800000000   │ 平台管理员             │
--   │ manager  │ manager@carelite.local  │ 13800000001   │ 王健康（企业管理根）   │
--   │ user     │ client1@carelite.local  │ 13800000002   │ 李明（客户）           │
--   │ user     │ client2@carelite.local  │ 13800000003   │ 王芳（客户）           │
--   └──────────┴─────────────────────────┴───────────────┴────────────────────────┘
--
-- 可见性配置说明（保证健康师登录后客户列表 / 详情页非空）：
--   * client_relations：两客户均以 status='active' 绑定王健康，customer_name 填档案姓名；
--   * profiles.privacy_settings：客户显式开启 share_records / share_vitals / show_phone /
--     data_analysis 四个键（can_manager_view_client_category 读取）；
--   * record_authorizations：王健康对两份本人档案持有永久有效授权（is_active=true、
--     expires_at=NULL，record_is_authorized 与档案/体成分 RLS 均依赖它）；
--   * merchant_module_grants：给王健康开通 view_health_records / view_health_insights /
--     view_conversations 三个数据模块（module_open_for_client 门槛）；
--   * enterprises：王健康是企业 owner（has_enterprise_permission 对 owner 恒真），
--     profiles.enterprise_id 指向该企业；
--   * body_compositions.oem_manager_id 保持 NULL（走 record_is_authorized 可见分支）。
--
-- 插入顺序（防外键）：auth.users（触发器 handle_new_user 自动建 profiles）
--   → enterprises / managers → profiles UPSERT（覆盖角色等）
--   → health_records → client_relations → record_authorizations
--   → merchant_module_grants → vital_signs → body_compositions
-- ============================================================================

BEGIN;

-- 演示账号密码用 pgcrypto 哈希（crypt/gen_salt）。本地栈默认已启用；
-- 云端 SQL Editor 手动执行时若报函数不存在，本行负责兜底。
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ----------------------------------------------------------------------------
-- 0) 清理旧演示数据（按外键安全顺序，保证本文件可重复执行）
-- ----------------------------------------------------------------------------
UPDATE public.profiles SET enterprise_id = NULL
WHERE id IN (
  '11111111-1111-4111-8111-111111111111', -- admin
  '22222222-2222-4222-8222-222222222222', -- 王健康
  '33333333-3333-4333-8333-333333333333', -- 李明
  '44444444-4444-4444-8444-444444444444'  -- 王芳
);

DELETE FROM public.merchant_module_grants
WHERE manager_id = '22222222-2222-4222-8222-222222222222';

DELETE FROM public.body_compositions
WHERE record_id IN (
  '66666666-6666-4666-8666-666666666666', -- 李明本人档案
  '77777777-7777-4777-8777-777777777777'  -- 王芳本人档案
);

DELETE FROM public.vital_signs
WHERE record_id IN (
  '66666666-6666-4666-8666-666666666666',
  '77777777-7777-4777-8777-777777777777'
);

DELETE FROM public.record_authorizations
WHERE record_id IN (
  '66666666-6666-4666-8666-666666666666',
  '77777777-7777-4777-8777-777777777777'
);

DELETE FROM public.client_relations
WHERE manager_id = '22222222-2222-4222-8222-222222222222'
   OR client_id IN (
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444'
);

DELETE FROM public.health_records
WHERE user_id IN (
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444'
);

DELETE FROM public.managers
WHERE id = '22222222-2222-4222-8222-222222222222';

DELETE FROM public.enterprises
WHERE id = '55555555-5555-4555-8555-555555555555';

DELETE FROM auth.users
WHERE id IN (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444'
);

DELETE FROM public.profiles
WHERE id IN (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444'
);

-- ----------------------------------------------------------------------------
-- 1) auth.users（社区标准写法，参照 20260910114500_seed_chronic_demo_account.sql
--    与 20260821164023 的字段集；banned_until 留 NULL 以允许登录）
--    auth.users.phone 用 E.164（+86 前缀），profiles.phone 存纯 11 位（与
--    get_manager_clients 的 '^1[0-9]{10}$' 掩码判断保持一致）。
--    raw_user_meta_data.nickname 为真实姓名（非「用户+数字」形态，会被
--    handle_new_user 采信）。
-- ----------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) VALUES
-- 平台管理员
(
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-4111-8111-111111111111',
  'authenticated', 'authenticated',
  'admin@carelite.local',
  '$2b$10$jwG1n5SU5CRzLeZ2INTtcOhkNmBkDBbj11bsU8H05n53cZ9Kf6xEu',
  now(), '+8613800000000', now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"nickname":"平台管理员"}'::jsonb,
  now(), now(), '', '', '', ''
),
-- 健康师（企业管理根）
(
  '00000000-0000-0000-0000-000000000000',
  '22222222-2222-4222-8222-222222222222',
  'authenticated', 'authenticated',
  'manager@carelite.local',
  '$2b$10$jwG1n5SU5CRzLeZ2INTtcOhkNmBkDBbj11bsU8H05n53cZ9Kf6xEu',
  now(), '+8613800000001', now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"nickname":"王健康"}'::jsonb,
  now(), now(), '', '', '', ''
),
-- 客户 1：李明
(
  '00000000-0000-0000-0000-000000000000',
  '33333333-3333-4333-8333-333333333333',
  'authenticated', 'authenticated',
  'client1@carelite.local',
  '$2b$10$jwG1n5SU5CRzLeZ2INTtcOhkNmBkDBbj11bsU8H05n53cZ9Kf6xEu',
  now(), '+8613800000002', now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"nickname":"李明"}'::jsonb,
  now(), now(), '', '', '', ''
),
-- 客户 2：王芳
(
  '00000000-0000-0000-0000-000000000000',
  '44444444-4444-4444-8444-444444444444',
  'authenticated', 'authenticated',
  'client2@carelite.local',
  '$2b$10$jwG1n5SU5CRzLeZ2INTtcOhkNmBkDBbj11bsU8H05n53cZ9Kf6xEu',
  now(), '+8613800000003', now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"nickname":"王芳"}'::jsonb,
  now(), now(), '', '', '', ''
);

-- ----------------------------------------------------------------------------
-- 2) 企业 + 健康师商户行（managers 行是 merchant_module_grants 的外键要求；
--    套餐 free 不做硬性客户数限制，客户端绑定触发器可正常通过）
-- ----------------------------------------------------------------------------
INSERT INTO public.enterprises (id, name, owner_profile_id, status, created_by, created_at, updated_at)
VALUES (
  '55555555-5555-4555-8555-555555555555',
  'CareLite 演示健康管理中心',
  '22222222-2222-4222-8222-222222222222',
  'active',
  '22222222-2222-4222-8222-222222222222',
  now(), now()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.managers (
  id, business_name, certification_status, membership_level,
  company_name, tagline, intro_personal,
  is_system_default, is_example, enterprise_id,
  created_at, updated_at
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  '王健康健康管理工作室', 'approved', 'free',
  'CareLite 演示健康管理中心', '慢病与体重管理 · 数据化随访',
  '演示健康师：擅长高血压、糖尿病及体重管理的长期随访。',
  false, false, '55555555-5555-4555-8555-555555555555',
  now(), now()
)
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3) profiles UPSERT（handle_new_user 已自动建行，这里覆盖角色/手机号/隐私等；
--    auth.role() 在 SQL 直连下为 NULL，角色字段更新不受防提权触发器限制）
--    王健康：role='manager' 且 parent_manager_id IS NULL → 企业管理根；
--    sub_role 留空字符串（根账号的生产惯例，非 'admin' 子账号语义）。
-- ----------------------------------------------------------------------------
INSERT INTO public.profiles (
  id, phone, nickname, role, sub_role, is_verified, real_name,
  privacy_settings, enterprise_id, parent_manager_id, is_disabled,
  created_at, updated_at
) VALUES
-- 平台管理员
(
  '11111111-1111-4111-8111-111111111111',
  '13800000000', '平台管理员', 'admin', '', true, '平台管理员',
  '{}'::jsonb, NULL, NULL, false,
  now(), now()
),
-- 健康师（企业根）
(
  '22222222-2222-4222-8222-222222222222',
  '13800000001', '王健康', 'manager', '', true, '王健康',
  '{}'::jsonb, '55555555-5555-4555-8555-555555555555', NULL, false,
  now(), now()
),
-- 客户 1：李明（隐私四键全部开启 → 对绑定健康师默认可见）
(
  '33333333-3333-4333-8333-333333333333',
  '13800000002', '李明', 'user', '', false, '李明',
  '{"share_records":true,"share_vitals":true,"show_phone":true,"data_analysis":true}'::jsonb,
  NULL, NULL, false,
  now(), now()
),
-- 客户 2：王芳
(
  '44444444-4444-4444-8444-444444444444',
  '13800000003', '王芳', 'user', '', false, '王芳',
  '{"share_records":true,"share_vitals":true,"show_phone":true,"data_analysis":true}'::jsonb,
  NULL, NULL, false,
  now(), now()
)
ON CONFLICT (id) DO UPDATE SET
  phone            = EXCLUDED.phone,
  nickname         = EXCLUDED.nickname,
  role             = EXCLUDED.role,
  sub_role         = EXCLUDED.sub_role,
  is_verified      = EXCLUDED.is_verified,
  real_name        = EXCLUDED.real_name,
  privacy_settings = EXCLUDED.privacy_settings,
  enterprise_id    = EXCLUDED.enterprise_id,
  parent_manager_id = EXCLUDED.parent_manager_id,
  is_disabled      = EXCLUDED.is_disabled,
  updated_at       = now();

-- ----------------------------------------------------------------------------
-- 4) 本人健康档案（health_records.user_id 外键指向 auth.users，已先插入）
-- ----------------------------------------------------------------------------
INSERT INTO public.health_records (
  id, user_id, name, relationship, gender, birth_date,
  height, weight, blood_type, medical_history, allergy_history,
  is_default, created_at, updated_at
) VALUES
(
  '66666666-6666-4666-8666-666666666666',
  '33333333-3333-4333-8333-333333333333',
  '李明', '本人', '男', '1984-05-12',
  175.00, 82.00, 'A型', '高血压家族史；2025 年体检提示血压偏高、超重', '青霉素过敏',
  true, now() - interval '90 days', now()
),
(
  '77777777-7777-4777-8777-777777777777',
  '44444444-4444-4444-8444-444444444444',
  '王芳', '本人', '女', '1991-03-08',
  162.00, 55.00, 'O型', '体健，年度体检未见明显异常', '无已知过敏',
  true, now() - interval '60 days', now()
)
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 5) 健康师-客户绑定（客户列表入口；root_manager_id/customer_name/
--    client_phone_normalized 与 20260822224412 迁移新增列对齐）
-- ----------------------------------------------------------------------------
INSERT INTO public.client_relations (
  id, manager_id, client_id, status, notes, last_contact_at,
  root_manager_id, customer_name, client_phone_normalized,
  created_at, updated_at
) VALUES
(
  '88888888-8888-4888-8888-888888888881',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  'active', '减重管理意向，每周电话随访一次',
  now() - interval '2 days',
  '22222222-2222-4222-8222-222222222222',
  '李明', '13800000002',
  now() - interval '30 days', now()
),
(
  '88888888-8888-4888-8888-888888888882',
  '22222222-2222-4222-8222-222222222222',
  '44444444-4444-4444-8444-444444444444',
  'active', '体重维持 + 体检报告解读需求',
  now() - interval '1 day',
  '22222222-2222-4222-8222-222222222222',
  '王芳', '13800000003',
  now() - interval '25 days', now()
)
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 6) 档案授权（永久有效：is_active=true、expires_at=NULL；
--    record_is_authorized / 体成分 RLS / 档案 RLS 均依赖此行）
-- ----------------------------------------------------------------------------
INSERT INTO public.record_authorizations (
  id, record_id, manager_id, granted_at, expires_at, is_active
) VALUES
(
  '99999999-9999-4999-8999-999999999901',
  '66666666-6666-4666-8666-666666666666',
  '22222222-2222-4222-8222-222222222222',
  now() - interval '30 days', NULL, true
),
(
  '99999999-9999-4999-8999-999999999902',
  '77777777-7777-4777-8777-777777777777',
  '22222222-2222-4222-8222-222222222222',
  now() - interval '25 days', NULL, true
)
ON CONFLICT (record_id, manager_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 7) 商户数据模块开通（module_open_for_client 门槛：
--    健康档案 / 健康洞察 / 会话三个数据类模块全部授予并开启）
-- ----------------------------------------------------------------------------
INSERT INTO public.merchant_module_grants (
  manager_id, module_key, grant_status, is_enabled, granted_by, notes
) VALUES
('22222222-2222-4222-8222-222222222222', 'view_health_records',  'granted', true, '11111111-1111-4111-8111-111111111111', '演示商户：默认开放健康档案模块'),
('22222222-2222-4222-8222-222222222222', 'view_health_insights', 'granted', true, '11111111-1111-4111-8111-111111111111', '演示商户：默认开放健康洞察模块'),
('22222222-2222-4222-8222-222222222222', 'view_conversations',   'granted', true, '11111111-1111-4111-8111-111111111111', '演示商户：默认开放会话模块')
ON CONFLICT (manager_id, module_key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 8) 体征记录（李明档案，近 7 天三个日期：血压逐步回落、体重递减）
-- ----------------------------------------------------------------------------
INSERT INTO public.vital_signs (
  id, record_id, heart_rate, systolic_pressure, diastolic_pressure,
  blood_sugar, weight, recorded_at, notes
) VALUES
(
  '12121212-1212-4212-8212-121212121201',
  '66666666-6666-4666-8666-666666666666',
  78, 142, 92, 6.30, 82.00,
  now() - interval '7 days', '晨起静息测量（演示数据）'
),
(
  '12121212-1212-4212-8212-121212121202',
  '66666666-6666-4666-8666-666666666666',
  76, 138, 88, 6.10, 81.00,
  now() - interval '4 days', '晨起静息测量（演示数据）'
),
(
  '12121212-1212-4212-8212-121212121203',
  '66666666-6666-4666-8666-666666666666',
  73, 132, 85, 5.80, 80.50,
  now() - interval '1 day', '晨起静息测量（演示数据）'
);

-- ----------------------------------------------------------------------------
-- 9) 体成分测量（客户列表 BMI 徽标读取 health_records.height +
--    body_compositions.weight；李明 82 → 81 → 80.5 递减趋势，王芳 1 条）
--    oem_manager_id 保持 NULL，走 record_is_authorized 可见分支。
-- ----------------------------------------------------------------------------
INSERT INTO public.body_compositions (
  record_id, measured_at, provider_key, origin,
  weight, bmi, body_fat_percent, health_score, notes
) VALUES
-- 李明：82kg（BMI 26.78 超重）
(
  '66666666-6666-4666-8666-666666666666',
  now() - interval '6 days', 'manual', 'manual',
  82.00, 26.78, 24.50, 71.0, '演示体成分数据（手动录入）'
),
-- 李明：81kg（BMI 26.45 超重）
(
  '66666666-6666-4666-8666-666666666666',
  now() - interval '3 days', 'manual', 'manual',
  81.00, 26.45, 24.00, 72.0, '演示体成分数据（手动录入）'
),
-- 李明：80.5kg（BMI 26.29 超重，趋势向好）
(
  '66666666-6666-4666-8666-666666666666',
  now() - interval '1 day', 'manual', 'manual',
  80.50, 26.29, 23.80, 72.5, '演示体成分数据（手动录入）'
),
-- 王芳：55kg（BMI 20.96 正常）
(
  '77777777-7777-4777-8777-777777777777',
  now() - interval '2 days', 'manual', 'manual',
  55.00, 20.96, 22.50, 81.0, '演示体成分数据（手动录入）'
);

COMMIT;
