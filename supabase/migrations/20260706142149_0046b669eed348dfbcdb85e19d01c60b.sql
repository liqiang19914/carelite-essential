ALTER TABLE public.membership_plans
  ADD COLUMN IF NOT EXISTS annual_price_cents integer NULL,
  ADD COLUMN IF NOT EXISTS online_purchase_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS shop_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS live_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS agent_training_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS oem_branding_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS custom_model_selection_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS manager_health_insight_enabled boolean NOT NULL DEFAULT false;

-- 回填 shop_enabled/live_enabled，保持与旧 shop_live_enabled 完全等价（仅旗舰版 true）
UPDATE public.membership_plans SET shop_enabled = shop_live_enabled, live_enabled = shop_live_enabled;

-- 价格与在线购买开关：仅基础版/高级版支持线上直接购买
UPDATE public.membership_plans SET annual_price_cents = 36500, online_purchase_enabled = true WHERE code = 'basic';
UPDATE public.membership_plans SET annual_price_cents = 298000, online_purchase_enabled = true WHERE code = 'advanced';

-- 智能体训练：现有功能对所有审核通过的管理师已开放，作为付费档起点权益展示（basic 及以上）
UPDATE public.membership_plans SET agent_training_enabled = true WHERE code IN ('basic', 'advanced', 'enterprise', 'flagship');

-- AI模型自选：功能尚未建成，先作为中高档展示卖点（advanced 及以上）
UPDATE public.membership_plans SET custom_model_selection_enabled = true WHERE code IN ('advanced', 'enterprise', 'flagship');

-- OEM品牌定制/专属品牌小程序 与 管理师端健康洞察：均对齐企业中心的门槛（enterprise 及以上）
UPDATE public.membership_plans SET oem_branding_enabled = true, manager_health_insight_enabled = true WHERE code IN ('enterprise', 'flagship');
