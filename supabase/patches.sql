-- ============================================================================
-- PGlite 补丁：在迁移后执行，修复因 Supabase 平台假设导致的缺失结构
-- ----------------------------------------------------------------------------
-- 根因：原始迁移假设 profiles.parent_manager_id 等列已存在（可能在 Supabase
-- 平台通过其他方式添加），但 PGlite 是空白实例，这些列缺失导致级联失败。
-- ============================================================================

-- 1) profiles 缺失列（被后续迁移引用）
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS parent_manager_id uuid;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS sub_role text DEFAULT '';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS permissions jsonb DEFAULT '{}'::jsonb;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_disabled boolean DEFAULT false;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS disabled_at timestamptz;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS disabled_reason text;

-- 2) managers 缺失列
ALTER TABLE public.managers ADD COLUMN IF NOT EXISTS parent_manager_id uuid;
ALTER TABLE public.managers ADD COLUMN IF NOT EXISTS enterprise_id uuid;

-- 3) auth.users 缺失列
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS banned_until timestamptz;

-- 4) auth.identities 表（Supabase Auth 标准结构，简化版）
CREATE TABLE IF NOT EXISTS auth.identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider_id text,
  provider text NOT NULL DEFAULT 'email',
  created_at timestamptz DEFAULT now(),
  last_sign_in_at timestamptz,
  identity_data jsonb DEFAULT '{}'::jsonb
);

-- 5) public.uid() — 某些迁移用 uid() 而非 auth.uid()
CREATE OR REPLACE FUNCTION public.uid()
RETURNS uuid AS $$
  SELECT auth.uid();
$$ LANGUAGE sql STABLE;

-- 6) gen_random_bytes — pgcrypto 函数 stub
CREATE OR REPLACE FUNCTION public.gen_random_bytes(n int)
RETURNS bytea AS $$
  SELECT decode(repeat('00', GREATEST(n, 1)), 'hex');
$$ LANGUAGE sql;

-- 7) pg_trgm 替代 — 创建空的扩展 schema 和占位函数
CREATE SCHEMA IF NOT EXISTS pg_trgm;
-- 某些迁移可能尝试 CREATE EXTENSION pg_trgm，这里创建占位
CREATE OR REPLACE FUNCTION extensions.similarity(text, text)
RETURNS float8 AS $$ SELECT 0.0; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION extensions.word_similarity(text, text)
RETURNS float8 AS $$ SELECT 0.0; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION extensions.show_limit()
RETURNS float8 AS $$ SELECT 0.3; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION extensions.show_trgm(text)
RETURNS text[] AS $$ SELECT ARRAY[]::text[]; $$ LANGUAGE sql;

-- 8) extensions.digest — pgcrypto 的哈希函数 stub
CREATE OR REPLACE FUNCTION extensions.digest(data text, algo text)
RETURNS bytea AS $$
  SELECT decode(md5(data), 'hex');
$$ LANGUAGE sql;

-- 9) realtime schema（迁移中可能引用）
CREATE SCHEMA IF NOT EXISTS realtime;

-- 10) cron schema（pg_cron 替代）
CREATE SCHEMA IF NOT EXISTS cron;

-- 11) oem_manager_id 列（OEM 白牌残留，触发器引用）
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS oem_manager_id uuid;
ALTER TABLE public.managers ADD COLUMN IF NOT EXISTS oem_manager_id uuid;
ALTER TABLE public.body_compositions ADD COLUMN IF NOT EXISTS oem_manager_id uuid;
