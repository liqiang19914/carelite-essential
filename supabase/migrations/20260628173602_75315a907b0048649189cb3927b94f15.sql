-- 邀请注册短码化：token uuid → 8 位 [a-z0-9] 短码
-- 模式照搬 generate_manager_short_code() / managers_set_short_code 触发器

-- 1) 先删除旧的 uuid 版撤销 RPC（签名变更，避免重载歧义）
DROP FUNCTION IF EXISTS public.admin_revoke_registration_invite(uuid);

-- 2) 8 位短码生成器（[a-z0-9]，10 次重试，唯一索引兜底）
CREATE OR REPLACE FUNCTION public.generate_registration_invite_code()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  alphabet TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  result TEXT;
  i INT;
  rand_idx INT;
  attempts INT := 0;
BEGIN
  LOOP
    attempts := attempts + 1;
    IF attempts > 10 THEN
      RAISE EXCEPTION 'registration invite code generation exceeded 10 attempts';
    END IF;
    result := '';
    FOR i IN 1..8 LOOP
      rand_idx := 1 + floor(random() * 36)::int;
      result := result || substr(alphabet, rand_idx, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.manager_registration_invites WHERE token = result
    );
  END LOOP;
  RETURN result;
END;
$$;

-- 3) 去默认值 + 改列类型（invites.token / attempts.token: uuid → text）
ALTER TABLE public.manager_registration_invites ALTER COLUMN token DROP DEFAULT;
ALTER TABLE public.manager_registration_invites ALTER COLUMN token TYPE text USING token::text;
ALTER TABLE public.manager_registration_attempts ALTER COLUMN token TYPE text USING token::text;

-- 4) 回填现存邀请为 8 位短码（逐行，事务内对后续 NOT EXISTS 可见）
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.manager_registration_invites LOOP
    UPDATE public.manager_registration_invites
       SET token = public.generate_registration_invite_code()
     WHERE id = r.id;
  END LOOP;
END $$;

-- 5) BEFORE INSERT 触发器：token 为空时自动填充短码
CREATE OR REPLACE FUNCTION public.manager_registration_invites_set_token()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.token IS NULL OR NEW.token = '' THEN
    NEW.token := public.generate_registration_invite_code();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS manager_registration_invites_set_token_before_insert ON public.manager_registration_invites;
CREATE TRIGGER manager_registration_invites_set_token_before_insert
  BEFORE INSERT ON public.manager_registration_invites
  FOR EACH ROW
  EXECUTE FUNCTION public.manager_registration_invites_set_token();

-- 6) 格式 CHECK（回填后再加，避免旧 36 位串违反约束）
ALTER TABLE public.manager_registration_invites
  DROP CONSTRAINT IF EXISTS manager_registration_invites_token_format_check;
ALTER TABLE public.manager_registration_invites
  ADD CONSTRAINT manager_registration_invites_token_format_check
  CHECK (token ~ '^[a-z0-9]{8}$');

-- 7) 确保 token 唯一索引存在（ALTER TYPE 会就地重建同名索引，IF NOT EXISTS 兜底）
CREATE UNIQUE INDEX IF NOT EXISTS manager_registration_invites_token_key
  ON public.manager_registration_invites (token);

-- 8) 重建撤销 RPC（p_token text），保持 admin 校验与 SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.admin_revoke_registration_invite(p_token text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_row public.manager_registration_invites;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;
  UPDATE public.manager_registration_invites
     SET is_active = false
   WHERE token = btrim(lower(p_token))
  RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION '邀请不存在';
  END IF;
  RETURN to_json(v_row);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_revoke_registration_invite(text) TO authenticated;