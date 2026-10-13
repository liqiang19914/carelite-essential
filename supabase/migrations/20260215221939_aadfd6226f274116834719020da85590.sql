
-- 1. 添加 RLS 策略：允许用户查看自己客户的 profiles
CREATE POLICY "Users can view client profiles via relations"
  ON profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM client_relations
      WHERE client_relations.client_id = profiles.id
      AND client_relations.manager_id = auth.uid()
    )
  );

-- 2. 创建 SECURITY DEFINER 函数：高效获取管理端客户列表（单次查询，绕过 RLS）
CREATE OR REPLACE FUNCTION get_manager_clients(p_manager_id UUID)
RETURNS TABLE (
  relation_id UUID,
  client_id UUID,
  status TEXT,
  notes TEXT,
  last_contact_at TIMESTAMPTZ,
  relation_created_at TIMESTAMPTZ,
  nickname TEXT,
  phone TEXT,
  avatar_url TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT 
    cr.id AS relation_id,
    cr.client_id,
    cr.status::text,
    cr.notes,
    cr.last_contact_at,
    cr.created_at AS relation_created_at,
    p.nickname::text,
    p.phone::text,
    p.avatar_url
  FROM client_relations cr
  LEFT JOIN profiles p ON p.id = cr.client_id
  WHERE cr.manager_id = p_manager_id
  ORDER BY cr.created_at DESC;
$$;

-- 3. 授权匿名和认证用户调用该函数
GRANT EXECUTE ON FUNCTION get_manager_clients(UUID) TO anon, authenticated;
