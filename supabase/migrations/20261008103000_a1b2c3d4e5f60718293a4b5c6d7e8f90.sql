-- ============================================================================
-- 商户 AI 官网 M1：站点 / 版本 / 建站对话 / 留资
-- 设计文档：docs/merchant-ai-website-m1-design.md
--
-- 约定：
--   * 新表全开 RLS、不直接授权，读写全走 SECURITY DEFINER RPC（SET search_path=''）
--   * 企业归属统一用 public.get_enterprise_root_manager_id(auth.uid())
--   * source_type 区分 AI 结构化站点（schema）与上传镜像站（html_bundle，M1 后期）
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 站点主表（一个 root 商户一行）
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_sites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  slug text NOT NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','published','offline')),
  source_type text NOT NULL DEFAULT 'schema'
    CHECK (source_type IN ('schema','html_bundle')),
  draft_version_id uuid,
  published_version_id uuid,
  seo jsonb NOT NULL DEFAULT '{"title":"","description":""}'::jsonb,
  published_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS merchant_sites_root_uniq
  ON public.merchant_sites (root_manager_id);
CREATE UNIQUE INDEX IF NOT EXISTS merchant_sites_slug_uniq
  ON public.merchant_sites (lower(slug));

ALTER TABLE public.merchant_sites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_sites FROM anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 版本快照（AI 每次存草稿 / 每次上传 都产生新版本，发布即快照、可回滚）
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_site_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES public.merchant_sites(id) ON DELETE CASCADE,
  version_no int NOT NULL,
  source_type text NOT NULL CHECK (source_type IN ('schema','html_bundle')),
  schema jsonb,
  bundle_oss_prefix text,
  manifest jsonb,
  review_status text NOT NULL DEFAULT 'none'
    CHECK (review_status IN ('none','in_review','approved','rejected')),
  review_reason text,
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamptz,
  source text NOT NULL DEFAULT 'chat'
    CHECK (source IN ('chat','manual','upload')),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  UNIQUE (site_id, version_no)
);

CREATE INDEX IF NOT EXISTS idx_site_versions_site
  ON public.merchant_site_versions (site_id, created_at DESC);

ALTER TABLE public.merchant_site_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_site_versions FROM anon, authenticated;

-- schema / bundle 互斥约束
CREATE OR REPLACE FUNCTION public.site_versions_type_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  IF NEW.source_type = 'schema' AND (NEW.schema IS NULL OR NEW.bundle_oss_prefix IS NOT NULL) THEN
    RAISE EXCEPTION 'schema 版本必须携带 schema 且不能携带 bundle' USING ERRCODE = 'P0002';
  END IF;
  IF NEW.source_type = 'html_bundle' AND (NEW.bundle_oss_prefix IS NULL OR NEW.schema IS NOT NULL) THEN
    RAISE EXCEPTION 'html_bundle 版本必须携带 bundle_oss_prefix 且不能携带 schema' USING ERRCODE = 'P0002';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_site_versions_type_guard ON public.merchant_site_versions;
CREATE TRIGGER trg_site_versions_type_guard
  BEFORE INSERT OR UPDATE ON public.merchant_site_versions
  FOR EACH ROW EXECUTE FUNCTION public.site_versions_type_guard();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 建站对话留痕（M1：AI 对话用量与排障；上下文以请求携带为准）
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_site_chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES public.merchant_sites(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user','assistant','system')),
  content text NOT NULL DEFAULT '',
  schema_snapshot jsonb,
  tokens_in int NOT NULL DEFAULT 0,
  tokens_out int NOT NULL DEFAULT 0,
  created_by uuid REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_site_chats_site
  ON public.merchant_site_chats (site_id, created_at);

ALTER TABLE public.merchant_site_chats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_site_chats FROM anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 官网留资
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_site_leads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES public.merchant_sites(id) ON DELETE CASCADE,
  version_id uuid REFERENCES public.merchant_site_versions(id),
  root_manager_id uuid NOT NULL,
  name text,
  phone text NOT NULL,
  remark text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_page text,
  ip_hash text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_site_leads_manager
  ON public.merchant_site_leads (root_manager_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_site_leads_ratelimit
  ON public.merchant_site_leads (phone, ip_hash, created_at DESC);

ALTER TABLE public.merchant_site_leads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_site_leads FROM anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. manager_domains 扩展：M2 自定义域名分流用，M1 先加列（默认 shop 不影响存量）
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.manager_domains
  ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'shop'
    CHECK (purpose IN ('shop','site')),
  ADD COLUMN IF NOT EXISTS site_id uuid
    REFERENCES public.merchant_sites(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_manager_domains_site
  ON public.manager_domains (site_id) WHERE site_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. 通用辅助
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.merchant_sites_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_merchant_sites_touch ON public.merchant_sites;
CREATE TRIGGER trg_merchant_sites_touch
  BEFORE UPDATE ON public.merchant_sites
  FOR EACH ROW EXECUTE FUNCTION public.merchant_sites_touch();

-- slug 合法性 + 保留字
CREATE OR REPLACE FUNCTION public.site_slug_is_valid(p_slug text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $function$
  SELECT p_slug ~ '^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$'
    AND p_slug <> ALL (ARRAY[
      'www','admin','api','m','s','w','b','site','shop','static','assets',
      'app','manage','manager','stores','store','blog','help','docs','mail',
      'ftp','test','dev','beta','preview','login','logout','oauth','status'
    ]);
$function$;

-- 把 brand_slug / short_code 清洗成合规 slug（不保证唯一，调用方负责避重）
CREATE OR REPLACE FUNCTION public.site_slug_normalize(p_raw text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $function$
DECLARE
  v text;
BEGIN
  v := lower(btrim(COALESCE(p_raw, '')));
  v := regexp_replace(v, '[^a-z0-9]+', '-', 'g');
  v := btrim(v, '-');
  IF length(v) < 3 THEN
    RETURN '';
  END IF;
  IF length(v) > 20 THEN
    v := substring(v FROM 1 FOR 20);
    v := btrim(v, '-');
  END IF;
  IF public.site_slug_is_valid(v) THEN
    RETURN v;
  END IF;
  RETURN '';
END;
$function$;

-- 为 root 商户挑一个不冲突的 slug
CREATE OR REPLACE FUNCTION public.site_slug_allocate(p_root uuid)
RETURNS text LANGUAGE plpgsql SET search_path = '' AS $function$
DECLARE
  v_base text;
  v_candidate text;
  v_suffix int := 0;
BEGIN
  SELECT COALESCE(
    public.site_slug_normalize(m.brand_slug),
    public.site_slug_normalize(m.short_code),
    '')
    INTO v_base
  FROM public.managers m
  WHERE m.id = p_root;

  IF v_base = '' THEN
    v_base := 'site-' || replace(substring(gen_random_uuid()::text FROM 1 FOR 8), '-', '');
  END IF;

  v_candidate := v_base;
  WHILE EXISTS (
    SELECT 1 FROM public.merchant_sites WHERE lower(slug) = lower(v_candidate)
  ) LOOP
    v_suffix := v_suffix + 1;
    v_candidate := substring(v_base FROM 1 FOR 18) || '-' || v_suffix::text;
  END LOOP;

  RETURN v_candidate;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. 商户侧 RPC
-- ─────────────────────────────────────────────────────────────────────────────

-- 7.1 概览：不存在则自动建站（首次进入零等待）
CREATE OR REPLACE FUNCTION public.site_my_overview()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site public.merchant_sites%ROWTYPE;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_site FROM public.merchant_sites WHERE root_manager_id = v_root;
  IF NOT FOUND THEN
    INSERT INTO public.merchant_sites (root_manager_id, slug, created_by)
    VALUES (v_root, public.site_slug_allocate(v_root), auth.uid())
    RETURNING * INTO v_site;
  END IF;

  RETURN jsonb_build_object(
    'id', v_site.id,
    'slug', v_site.slug,
    'status', v_site.status,
    'sourceType', v_site.source_type,
    'draftVersionId', v_site.draft_version_id,
    'publishedVersionId', v_site.published_version_id,
    'seo', v_site.seo,
    'publishedAt', v_site.published_at,
    'updatedAt', v_site.updated_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.site_my_overview() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_my_overview() TO authenticated;

-- 7.2 保存 schema 草稿（产生新版本号）
CREATE OR REPLACE FUNCTION public.site_save_draft_schema(p_schema jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site public.merchant_sites%ROWTYPE;
  v_no int;
  v_version uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_schema) <> 'object'
     OR jsonb_typeof(p_schema->'page') <> 'object'
     OR jsonb_typeof(p_schema->'page'->'blocks') <> 'array' THEN
    RAISE EXCEPTION '页面结构不合法' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_site FROM public.merchant_sites WHERE root_manager_id = v_root FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '站点不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(max(version_no), 0) + 1 INTO v_no
    FROM public.merchant_site_versions WHERE site_id = v_site.id;

  INSERT INTO public.merchant_site_versions
    (site_id, version_no, source_type, schema, source, created_by)
  VALUES (v_site.id, v_no, 'schema', p_schema, 'manual', auth.uid())
  RETURNING id INTO v_version;

  UPDATE public.merchant_sites
     SET draft_version_id = v_version, source_type = 'schema', updated_at = now()
   WHERE id = v_site.id;

  RETURN jsonb_build_object('id', v_version, 'versionNo', v_no, 'reviewStatus', 'none');
END;
$function$;

REVOKE ALL ON FUNCTION public.site_save_draft_schema(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_save_draft_schema(jsonb) TO authenticated;

-- 7.3 版本列表（不含大字段）
CREATE OR REPLACE FUNCTION public.site_list_versions()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_rows jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.version_no DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT id, version_no, source_type, review_status, review_reason,
           source, published_at, created_at
    FROM public.merchant_site_versions
    WHERE site_id = (SELECT id FROM public.merchant_sites WHERE root_manager_id = v_root)
  ) v;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.site_list_versions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_list_versions() TO authenticated;

-- 7.4 读取某个版本详情（含 schema / manifest）
CREATE OR REPLACE FUNCTION public.site_get_version(p_version_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_row jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(v) INTO v_row
  FROM public.merchant_site_versions v
  JOIN public.merchant_sites s ON s.id = v.site_id
  WHERE v.id = p_version_id AND s.root_manager_id = v_root;

  IF v_row IS NULL THEN
    RAISE EXCEPTION '版本不存在' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END;
$function$;

REVOKE ALL ON FUNCTION public.site_get_version(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_get_version(uuid) TO authenticated;

-- 7.5 修改 slug / seo（发布前可自由改；已发布限制 30 天一次，见 R6，M1 先只允许非 published 改）
CREATE OR REPLACE FUNCTION public.site_update_meta(p_slug text, p_seo jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site public.merchant_sites%ROWTYPE;
  v_slug text;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_site FROM public.merchant_sites WHERE root_manager_id = v_root FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '站点不存在' USING ERRCODE = 'P0002';
  END IF;

  v_slug := lower(btrim(COALESCE(p_slug, v_site.slug)));
  IF NOT public.site_slug_is_valid(v_slug) THEN
    RAISE EXCEPTION '标识格式不正确或为保留字（3-20 位小写字母/数字/短横）' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.merchant_sites
    WHERE lower(slug) = v_slug AND id <> v_site.id
  ) THEN
    RAISE EXCEPTION '该标识已被占用' USING ERRCODE = '23505';
  END IF;

  UPDATE public.merchant_sites SET
    slug = v_slug,
    seo = CASE WHEN p_seo IS NULL THEN seo ELSE p_seo END
  WHERE id = v_site.id
  RETURNING * INTO v_site;

  RETURN jsonb_build_object('id', v_site.id, 'slug', v_site.slug, 'seo', v_site.seo);
END;
$function$;

REVOKE ALL ON FUNCTION public.site_update_meta(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_update_meta(text, jsonb) TO authenticated;

-- 7.6 发布：仅审核通过的版本可发布（自动审核在 edge 侧完成后置 approved）
CREATE OR REPLACE FUNCTION public.site_publish(p_version_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site_id uuid;
  v_site public.merchant_sites%ROWTYPE;
  v_status text;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT v.site_id, v.review_status INTO v_site_id, v_status
  FROM public.merchant_site_versions v
  JOIN public.merchant_sites s ON s.id = v.site_id
  WHERE v.id = p_version_id AND s.root_manager_id = v_root
  FOR UPDATE OF v;

  IF v_site_id IS NULL THEN
    RAISE EXCEPTION '版本不存在' USING ERRCODE = 'P0002';
  END IF;
  IF v_status <> 'approved' THEN
    RAISE EXCEPTION '内容审核未通过，暂时不能发布' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.merchant_site_versions
     SET published_at = now()
   WHERE id = p_version_id;

  UPDATE public.merchant_sites
     SET status = 'published',
         published_version_id = p_version_id,
         published_at = now(),
         updated_at = now()
   WHERE id = v_site_id
  RETURNING * INTO v_site;

  RETURN jsonb_build_object(
    'id', v_site.id, 'status', v_site.status,
    'publishedVersionId', v_site.published_version_id,
    'publishedAt', v_site.published_at);
END;
$function$;

REVOKE ALL ON FUNCTION public.site_publish(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_publish(uuid) TO authenticated;

-- 7.7 回滚：把已发布过的历史版本重新置为线上（再记一次 published_at）
CREATE OR REPLACE FUNCTION public.site_rollback(p_version_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_site public.merchant_sites%ROWTYPE;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT s.* INTO v_site
  FROM public.merchant_sites s
  JOIN public.merchant_site_versions v ON v.site_id = s.id
  WHERE v.id = p_version_id AND s.root_manager_id = v_root
    AND v.review_status = 'approved';
  IF NOT FOUND THEN
    RAISE EXCEPTION '仅已审核通过的版本可以回滚' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.merchant_site_versions SET published_at = now() WHERE id = p_version_id;
  UPDATE public.merchant_sites
     SET status = 'published', published_version_id = p_version_id,
         published_at = now(), updated_at = now()
   WHERE id = v_site.id
  RETURNING * INTO v_site;

  RETURN jsonb_build_object(
    'id', v_site.id, 'status', v_site.status,
    'publishedVersionId', v_site.published_version_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.site_rollback(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_rollback(uuid) TO authenticated;

-- 7.8 上线 / 下线开关
CREATE OR REPLACE FUNCTION public.site_set_offline(p_offline boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_sites
     SET status = CASE WHEN p_offline THEN 'offline' ELSE 'published' END,
         updated_at = now()
   WHERE root_manager_id = v_root
     AND (p_offline = false OR published_version_id IS NOT NULL);

  RETURN found;
END;
$function$;

REVOKE ALL ON FUNCTION public.site_set_offline(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_set_offline(boolean) TO authenticated;

-- 7.9 商户查自己的线索
CREATE OR REPLACE FUNCTION public.site_list_leads(p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_root uuid;
  v_rows jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT id, name, phone, remark, payload, source_page, created_at
    FROM public.merchant_site_leads
    WHERE root_manager_id = v_root
    ORDER BY created_at DESC
    LIMIT GREATEST(LEAST(p_limit, 200), 1)
    OFFSET GREATEST(p_offset, 0)
  ) l;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.site_list_leads(int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_list_leads(int, int) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. 匿名侧 RPC（公开页 / 留资）
-- ─────────────────────────────────────────────────────────────────────────────

-- 8.1 按 slug 读已发布官网（只返回渲染所需字段）
CREATE OR REPLACE FUNCTION public.site_public_by_slug(p_slug text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_site public.merchant_sites%ROWTYPE;
  v_ver public.merchant_site_versions%ROWTYPE;
  v_brand jsonb;
BEGIN
  SELECT * INTO v_site
  FROM public.merchant_sites
  WHERE lower(slug) = lower(btrim(p_slug));

  IF NOT FOUND OR v_site.status <> 'published' OR v_site.published_version_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_ver FROM public.merchant_site_versions WHERE id = v_site.published_version_id;

  -- 品牌名取 profiles.display_name；完整品牌配置（logo/主色）在独立 OEM 表，
  -- 由前端渲染时按 rootManagerId 走现有 get-oem-brand 公开函数补齐。
  SELECT jsonb_build_object(
    'brandName', p.display_name,
    'brandSlug', m.brand_slug,
    'shortCode', m.short_code
  ) INTO v_brand
  FROM public.managers m
  JOIN public.profiles p ON p.id = m.id
  WHERE m.id = v_site.root_manager_id;

  RETURN jsonb_build_object(
    'slug', v_site.slug,
    'sourceType', v_site.source_type,
    'rootManagerId', v_site.root_manager_id,
    'brand', v_brand,
    'versionId', v_ver.id,
    'schema', v_ver.schema,
    'manifest', v_ver.manifest,
    'bundleOssPrefix', v_ver.bundle_oss_prefix,
    'seo', v_site.seo,
    'publishedAt', v_site.published_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.site_public_by_slug(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_public_by_slug(text) TO anon, authenticated;

-- 8.2 公开留资（由 edge function 校验手机号/频控后调用；ip_hash 由函数侧根据 header 生成）
CREATE OR REPLACE FUNCTION public.site_submit_lead(
  p_slug text,
  p_name text,
  p_phone text,
  p_remark text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_source_page text DEFAULT NULL,
  p_ip_hash text DEFAULT ''
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_site public.merchant_sites%ROWTYPE;
  v_phone text;
  v_id uuid;
  v_recent int;
BEGIN
  SELECT * INTO v_site
  FROM public.merchant_sites
  WHERE lower(slug) = lower(btrim(p_slug));

  IF NOT FOUND OR v_site.status <> 'published' THEN
    RAISE EXCEPTION '站点不存在或已下线' USING ERRCODE = 'P0002';
  END IF;

  v_phone := regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g');
  WHILE length(v_phone) > 11 AND left(v_phone, 2) = '86' LOOP
    v_phone := substring(v_phone FROM 3);
  END LOOP;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '请输入正确的手机号' USING ERRCODE = 'P0002';
  END IF;

  -- 频控：同手机号 + IP 60 秒内 1 次
  SELECT count(*) INTO v_recent
  FROM public.merchant_site_leads
  WHERE phone = v_phone
    AND ip_hash = p_ip_hash
    AND created_at > now() - interval '60 seconds';
  IF v_recent > 0 THEN
    RAISE EXCEPTION '提交过于频繁，请稍后再试' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.merchant_site_leads
    (site_id, version_id, root_manager_id, name, phone, remark, payload, source_page, ip_hash)
  VALUES (
    v_site.id, v_site.published_version_id, v_site.root_manager_id,
    left(btrim(COALESCE(p_name, '')), 50),
    v_phone,
    left(btrim(COALESCE(p_remark, '')), 500),
    COALESCE(p_payload, '{}'::jsonb),
    left(btrim(COALESCE(p_source_page, '')), 200),
    left(btrim(COALESCE(p_ip_hash, '')), 128)
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.site_submit_lead(text,text,text,text,jsonb,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.site_submit_lead(text,text,text,text,jsonb,text,text) TO anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. 平台侧审核 RPC
-- ─────────────────────────────────────────────────────────────────────────────

-- 9.1 待审 / 全量版本队列
CREATE OR REPLACE FUNCTION public.admin_site_review_list(p_pending_only boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT v.id AS version_id, v.version_no, v.source_type, v.review_status,
           v.review_reason, v.source, v.created_at,
           s.id AS site_id, s.slug, s.root_manager_id,
           p.display_name AS merchant_name
    FROM public.merchant_site_versions v
    JOIN public.merchant_sites s ON s.id = v.site_id
    JOIN public.profiles p ON p.id = s.root_manager_id
    WHERE (NOT p_pending_only OR v.review_status = 'in_review')
    LIMIT 200
  ) x;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_site_review_list(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_site_review_list(boolean) TO authenticated;

-- 9.2 审核判定（edge 自动审核也通过 service_role 调用同一路径）
CREATE OR REPLACE FUNCTION public.admin_site_review_decision(
  p_version_id uuid,
  p_approve boolean,
  p_reason text DEFAULT NULL,
  p_auto boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_site_id uuid;
  v_status text;
BEGIN
  IF NOT p_auto AND NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_site_versions
     SET review_status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         review_reason = CASE WHEN p_approve THEN NULL ELSE left(COALESCE(p_reason, ''), 1000) END,
         reviewed_by = CASE WHEN p_auto THEN NULL ELSE auth.uid() END,
         reviewed_at = now()
   WHERE id = p_version_id
  RETURNING site_id, review_status INTO v_site_id, v_status;

  IF v_site_id IS NULL THEN
    RAISE EXCEPTION '版本不存在' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('versionId', p_version_id, 'siteId', v_site_id, 'reviewStatus', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_site_review_decision(uuid, boolean, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_site_review_decision(uuid, boolean, text, boolean) TO authenticated, service_role;
