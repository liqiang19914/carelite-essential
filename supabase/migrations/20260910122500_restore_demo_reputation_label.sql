-- 演示账号沿用系统默认栏目名“达人口碑”，不再用主题文案覆盖管理端菜单。
UPDATE public.manager_content_spaces
SET reputation_name = NULL,
    updated_at = now()
WHERE root_manager_id IN (
  '9d20bc6b-cbd4-4153-84e5-01e5b58f041f'::uuid,
  'c6cc187c-3b13-40fc-befb-aa70594ebe3c'::uuid,
  'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e'::uuid
);
