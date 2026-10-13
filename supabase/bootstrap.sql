-- ============================================================================
-- PGlite bootstrap：在执行迁移前预建 Supabase 平台基础设施
-- ----------------------------------------------------------------------------
-- PGlite 是空白 PostgreSQL，缺少 Supabase 平台预建的 auth/extensions/storage 等
-- schema。本文件在迁移前执行，创建必要的基础结构。
-- ============================================================================

-- 1) extensions schema（pgcrypto 替代）
CREATE SCHEMA IF NOT EXISTS extensions;

-- pgcrypto 的 crypt/gen_salt 在 PGlite 中不可用，创建 stub 函数让 SQL 不报错。
-- 实际密码验证在前端用 bcryptjs 完成，不走 SQL。
-- 注意：迁移中可能用 gen_salt('bf') 或 gen_salt('bf', 10)，需要多个重载签名。
-- 不带 schema 前缀的 gen_salt/crypt 也需要创建（迁移中可能直接调用）。
CREATE OR REPLACE FUNCTION extensions.gen_salt(algorithm text)
RETURNS text AS $$ SELECT 'pglite_stub_salt'; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION extensions.gen_salt(algorithm text, rounds int)
RETURNS text AS $$ SELECT 'pglite_stub_salt'; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION extensions.crypt(p_password text, p_salt text)
RETURNS text AS $$ SELECT 'pglite_stub_hash'; $$ LANGUAGE sql;
-- 不带 schema 的版本（某些迁移直接用 gen_salt() 而非 extensions.gen_salt()）
CREATE OR REPLACE FUNCTION public.gen_salt(algorithm text)
RETURNS text AS $$ SELECT 'pglite_stub_salt'; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION public.gen_salt(algorithm text, rounds int)
RETURNS text AS $$ SELECT 'pglite_stub_salt'; $$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION public.crypt(p_password text, p_salt text)
RETURNS text AS $$ SELECT 'pglite_stub_hash'; $$ LANGUAGE sql;

-- 2) auth schema
CREATE SCHEMA IF NOT EXISTS auth;

-- auth.users 表（Supabase GoTrue 标准结构）
CREATE TABLE IF NOT EXISTS auth.users (
  instance_id uuid DEFAULT gen_random_uuid(),
  id uuid PRIMARY KEY,
  aud varchar DEFAULT 'authenticated',
  role varchar DEFAULT 'authenticated',
  email varchar,
  encrypted_password text,
  email_confirmed_at timestamptz,
  phone varchar,
  phone_confirmed_at timestamptz,
  raw_app_meta_data jsonb DEFAULT '{}'::jsonb,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
  is_sso_user boolean DEFAULT false,
  deleted_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  confirmation_token varchar DEFAULT '',
  recovery_token varchar DEFAULT '',
  email_change_token_new varchar DEFAULT '',
  email_change_token_old varchar DEFAULT '',
  email_change varchar DEFAULT '',
  last_sign_in_at timestamptz,
  raw_app_meta_data_version int DEFAULT 1,
  raw_user_meta_data_version int DEFAULT 1
);

-- auth.uid() — Supabase RLS 的核心函数。PGlite 中无法从 JWT 解析，
-- 改为从 session 变量读取，由 adapter 层设置。
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid AS $$
  SELECT NULLIF(current_setting('app.current_uid', true), '')::uuid;
$$ LANGUAGE sql;

-- auth.email() — 同理
CREATE OR REPLACE FUNCTION auth.email()
RETURNS text AS $$
  SELECT NULLIF(current_setting('app.current_email', true), '');
$$ LANGUAGE sql;

-- auth.role() — 返回当前角色
CREATE OR REPLACE FUNCTION auth.role()
RETURNS text AS $$
  SELECT NULLIF(current_setting('app.current_role', true), '') || 'authenticated';
$$ LANGUAGE sql;

-- 3) Supabase 角色（GRANT 语句需要）
-- PGlite 是单用户模式，CREATE ROLE 可能不支持，用 DO 块做容错
DO $$ BEGIN
  CREATE ROLE anon NOLOGIN;
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE authenticated NOLOGIN;
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE service_role NOLOGIN;
EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE postgres NOLOGIN;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- 4) storage schema（空壳，避免迁移中引用报错）
CREATE SCHEMA IF NOT EXISTS storage;

-- 5) graphql schema（空壳）
CREATE SCHEMA IF NOT EXISTS graphql;

-- 6) supabase_realtime publication（迁移中可能引用）
DO $$ BEGIN
  CREATE PUBLICATION supabase_realtime;
EXCEPTION WHEN OTHERS THEN NULL; END $$;
