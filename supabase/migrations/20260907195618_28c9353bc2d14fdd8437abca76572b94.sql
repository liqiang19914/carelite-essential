-- 457 补充：注册邀请 token 对齐 6 位 [a-z0-9] 全站规范。
-- 存量 8 位短码与更早的历史 UUID 串全部保留可解析（解析端按 token 精确文本匹配，无格式假设）；
-- 格式 CHECK 相应放宽，新行由既有 BEFORE INSERT 触发器自动生成 6 位码（单一收口点，不重复散落生成）。

CREATE OR REPLACE FUNCTION public.generate_registration_invite_code()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $function$
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
    FOR i IN 1..6 LOOP
      rand_idx := 1 + floor(random() * 36)::int;
      result := result || substr(alphabet, rand_idx, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.manager_registration_invites WHERE token = result
    );
  END LOOP;
  RETURN result;
END;
$function$;

ALTER TABLE public.manager_registration_invites
  DROP CONSTRAINT IF EXISTS manager_registration_invites_token_format_check;
ALTER TABLE public.manager_registration_invites
  ADD CONSTRAINT manager_registration_invites_token_format_check
  CHECK (
    token ~ '^[a-z0-9]{6}$'
    OR token ~ '^[a-z0-9]{8}$'
    OR token ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  );