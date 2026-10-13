-- ============================================================
-- 设备能力台账（平台级）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.device_providers (
  provider_key text PRIMARY KEY,
  display_name text NOT NULL,
  integration_type text NOT NULL CHECK (integration_type IN ('mp_plugin','ble_standard','werun','cloud_oauth','odm_ble','manual')),
  auth_model text NOT NULL CHECK (auth_model IN ('open','vendor_key','exclusive_bind')),
  data_domain text NOT NULL CHECK (data_domain IN ('body_composition','vital','activity')),
  plugin_provider_appid text,
  plugin_version text,
  required_request_domains text[] NOT NULL DEFAULT '{}',
  required_privacy_apis text[] NOT NULL DEFAULT '{}',
  entry_page text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','deprecated')),
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.device_providers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read device providers" ON public.device_providers;
CREATE POLICY "Anyone can read device providers"
  ON public.device_providers FOR SELECT TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Admins manage device providers" ON public.device_providers;
CREATE POLICY "Admins manage device providers"
  ON public.device_providers FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

INSERT INTO public.device_providers (
  provider_key, display_name, integration_type, auth_model, data_domain,
  plugin_provider_appid, plugin_version, required_privacy_apis, entry_page, description
) VALUES (
  'yolanda_scale', '云康宝体脂秤', 'mp_plugin', 'open', 'body_composition',
  'wx2a4ca48ed5e96748', '4.9.7',
  ARRAY['BluetoothAPI','LocationAPI'],
  '/pages/weigh/index',
  '轻牛 QNBleApi 小程序插件，四电极机型 CS20H1，16 项体成分指标 + 健康评分'
) ON CONFLICT (provider_key) DO UPDATE
  SET plugin_version = EXCLUDED.plugin_version,
      plugin_provider_appid = EXCLUDED.plugin_provider_appid,
      entry_page = EXCLUDED.entry_page,
      updated_at = now();

-- ============================================================
-- 逐 OEM 硬件授权
-- ============================================================
CREATE TABLE IF NOT EXISTS public.oem_device_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  provider_key text NOT NULL REFERENCES public.device_providers(provider_key) ON DELETE CASCADE,
  grant_status text NOT NULL DEFAULT 'not_applied' CHECK (grant_status IN ('not_applied','applied','granted','revoked')),
  is_enabled boolean NOT NULL DEFAULT false,
  metric_whitelist text[],
  provider_config jsonb,
  granted_at timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT oem_device_grants_manager_provider_key UNIQUE (manager_id, provider_key)
);

CREATE INDEX IF NOT EXISTS oem_device_grants_manager ON public.oem_device_grants (manager_id);

ALTER TABLE public.oem_device_grants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage oem device grants" ON public.oem_device_grants;
CREATE POLICY "Admins manage oem device grants"
  ON public.oem_device_grants FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Managers read own device grants" ON public.oem_device_grants;
CREATE POLICY "Managers read own device grants"
  ON public.oem_device_grants FOR SELECT TO authenticated
  USING (manager_id = auth.uid());

INSERT INTO public.oem_device_grants (manager_id, provider_key, grant_status, is_enabled, granted_at, notes)
VALUES (
  '5424dfb1-f528-436c-bd75-2028e3c2e286', 'yolanda_scale', 'granted', true, now(),
  '卓越耀美（耀美管家 wxefdef5b25533b535）已在小程序后台添加 QNBleApi 插件并通过授权'
) ON CONFLICT (manager_id, provider_key) DO UPDATE
  SET grant_status = EXCLUDED.grant_status,
      is_enabled = EXCLUDED.is_enabled,
      granted_at = COALESCE(public.oem_device_grants.granted_at, EXCLUDED.granted_at),
      updated_at = now();

-- ============================================================
-- 一次性测量票据：原生页不持有任何用户凭证
-- ============================================================
CREATE TABLE IF NOT EXISTS public.measure_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket text NOT NULL UNIQUE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  record_id uuid NOT NULL REFERENCES public.health_records(id) ON DELETE CASCADE,
  provider_key text NOT NULL REFERENCES public.device_providers(provider_key) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS measure_tickets_open
  ON public.measure_tickets (ticket) WHERE consumed_at IS NULL;

ALTER TABLE public.measure_tickets ENABLE ROW LEVEL SECURITY;
-- 故意不建任何 authenticated/anon 策略：签发只能走 RPC，核销只能走 service_role

DROP POLICY IF EXISTS "Service role manages measure tickets" ON public.measure_tickets;
CREATE POLICY "Service role manages measure tickets"
  ON public.measure_tickets FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.create_measure_ticket(p_record_id uuid, p_provider_key text)
RETURNS TABLE (ticket text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ticket text;
  v_expires timestamptz := now() + interval '10 minutes';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT public.owns_health_record(v_uid, p_record_id) THEN
    RAISE EXCEPTION 'record_not_owned';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.device_providers
    WHERE provider_key = p_provider_key AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'provider_unavailable';
  END IF;

  DELETE FROM public.measure_tickets WHERE expires_at < now() - interval '7 days';

  v_ticket := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO public.measure_tickets (ticket, user_id, record_id, provider_key, expires_at)
  VALUES (v_ticket, v_uid, p_record_id, p_provider_key, v_expires);

  RETURN QUERY SELECT v_ticket, v_expires;
END;
$$;

REVOKE ALL ON FUNCTION public.create_measure_ticket(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_measure_ticket(uuid, text) TO authenticated;

-- ============================================================
-- OEM 品牌主色
-- ============================================================
ALTER TABLE public.manager_miniprograms
  ADD COLUMN IF NOT EXISTS brand_primary_color text;

ALTER TABLE public.manager_miniprograms
  DROP CONSTRAINT IF EXISTS manager_miniprograms_brand_primary_color_hex;
ALTER TABLE public.manager_miniprograms
  ADD CONSTRAINT manager_miniprograms_brand_primary_color_hex
  CHECK (brand_primary_color IS NULL OR brand_primary_color ~* '^#([0-9a-f]{3}|[0-9a-f]{6})$');

INSERT INTO public.system_settings (key, value, description)
VALUES ('miniapp_brand_primary_color', '#E8720C', '平台默认品牌主色（HEX），OEM 未配置时回落到此值')
ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE public.device_providers IS '设备接入能力台账：插件供应商 AppID、钉定版本、入口页、所需隐私接口';
COMMENT ON TABLE public.oem_device_grants IS '逐 OEM 的硬件授权与开关；仅控制产品入口，不作为数据安全边界';
COMMENT ON TABLE public.measure_tickets IS '一次性测量票据（10 分钟），原生测量页凭此提交数据，自身不持有任何用户凭证';