-- ============================================================================
-- 健康管理师 OEM 小程序：表 + RLS + 5 个 SECURITY DEFINER RPC
-- ============================================================================

-- ─── 1. Table ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.manager_miniprograms (
  manager_id       uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  is_enabled       boolean NOT NULL DEFAULT false,

  app_name         text,
  app_id           text,
  app_secret       text,
  original_id      text,
  upload_key       text,
  version          text NOT NULL DEFAULT '1.0.0',

  request_domain   text,
  socket_domain    text,
  upload_domain    text,
  download_domain  text,
  udp_domain       text,
  business_domain  text,

  target_path      text NOT NULL DEFAULT '/login',

  created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT manager_miniprograms_target_path_check CHECK (target_path LIKE '/%')
);

-- partial unique index — allow multiple empty app_id
CREATE UNIQUE INDEX IF NOT EXISTS manager_miniprograms_app_id_key
  ON public.manager_miniprograms (app_id)
  WHERE app_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS manager_miniprograms_enabled_idx
  ON public.manager_miniprograms (is_enabled)
  WHERE is_enabled = true;

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.manager_miniprograms_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS manager_miniprograms_touch_updated_at_trg ON public.manager_miniprograms;
CREATE TRIGGER manager_miniprograms_touch_updated_at_trg
  BEFORE UPDATE ON public.manager_miniprograms
  FOR EACH ROW EXECUTE FUNCTION public.manager_miniprograms_touch_updated_at();

-- ─── 2. RLS ────────────────────────────────────────────────────────────────

ALTER TABLE public.manager_miniprograms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_miniprograms_select_admin ON public.manager_miniprograms;
CREATE POLICY manager_miniprograms_select_admin
  ON public.manager_miniprograms FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS manager_miniprograms_select_self ON public.manager_miniprograms;
CREATE POLICY manager_miniprograms_select_self
  ON public.manager_miniprograms FOR SELECT
  TO authenticated
  USING (manager_id = auth.uid());

-- writes locked down: only via RPCs
REVOKE INSERT, UPDATE, DELETE ON public.manager_miniprograms FROM authenticated, anon;
GRANT SELECT ON public.manager_miniprograms TO authenticated;

-- ─── 3. Helper: field whitelist applier (config writes) ────────────────────

-- Used by admin_save_manager_oem_config and manager_save_my_oem_config.
-- Returns the row id; mutates the row's whitelisted fields based on jsonb keys present.
CREATE OR REPLACE FUNCTION public._manager_miniprograms_apply_config(
  p_manager_id uuid,
  p_config jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_app_id text;
BEGIN
  -- Normalize app_id once for unique-conflict messaging
  IF p_config ? 'app_id' THEN
    v_app_id := NULLIF(btrim(p_config->>'app_id'), '');
    IF v_app_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.manager_miniprograms
      WHERE app_id = v_app_id AND manager_id <> p_manager_id
    ) THEN
      RAISE EXCEPTION 'AppID 已被其他管理师使用，请检查' USING ERRCODE = '23505';
    END IF;
  END IF;

  UPDATE public.manager_miniprograms
  SET
    app_name        = CASE WHEN p_config ? 'app_name'        THEN NULLIF(btrim(p_config->>'app_name'), '')        ELSE app_name END,
    app_id          = CASE WHEN p_config ? 'app_id'          THEN NULLIF(btrim(p_config->>'app_id'), '')          ELSE app_id END,
    app_secret      = CASE WHEN p_config ? 'app_secret'      THEN NULLIF(btrim(p_config->>'app_secret'), '')      ELSE app_secret END,
    original_id     = CASE WHEN p_config ? 'original_id'     THEN NULLIF(btrim(p_config->>'original_id'), '')     ELSE original_id END,
    upload_key      = CASE WHEN p_config ? 'upload_key'      THEN NULLIF(btrim(p_config->>'upload_key'), '')      ELSE upload_key END,
    version         = CASE WHEN p_config ? 'version'         THEN COALESCE(NULLIF(btrim(p_config->>'version'), ''), '1.0.0') ELSE version END,
    request_domain  = CASE WHEN p_config ? 'request_domain'  THEN NULLIF(btrim(p_config->>'request_domain'), '')  ELSE request_domain END,
    socket_domain   = CASE WHEN p_config ? 'socket_domain'   THEN NULLIF(btrim(p_config->>'socket_domain'), '')   ELSE socket_domain END,
    upload_domain   = CASE WHEN p_config ? 'upload_domain'   THEN NULLIF(btrim(p_config->>'upload_domain'), '')   ELSE upload_domain END,
    download_domain = CASE WHEN p_config ? 'download_domain' THEN NULLIF(btrim(p_config->>'download_domain'), '') ELSE download_domain END,
    udp_domain      = CASE WHEN p_config ? 'udp_domain'      THEN NULLIF(btrim(p_config->>'udp_domain'), '')      ELSE udp_domain END,
    business_domain = CASE WHEN p_config ? 'business_domain' THEN NULLIF(btrim(p_config->>'business_domain'), '') ELSE business_domain END,
    target_path     = CASE WHEN p_config ? 'target_path'     THEN COALESCE(
                                                              (
                                                                SELECT CASE
                                                                  WHEN tp LIKE '/%' THEN tp
                                                                  WHEN tp IS NULL OR tp = '' THEN '/login'
                                                                  ELSE '/' || tp
                                                                END
                                                                FROM (SELECT NULLIF(btrim(p_config->>'target_path'), '') AS tp) sub
                                                              ),
                                                              '/login'
                                                            )
                                                       ELSE target_path END,
    updated_by      = auth.uid()
  WHERE manager_id = p_manager_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._manager_miniprograms_apply_config(uuid, jsonb) FROM PUBLIC, authenticated, anon;