
-- client_relations.client_id 原先引用 auth.users(id)，
-- 改为引用 profiles(id)，因为 profiles 已解除对 auth.users 的外键，
-- 可以存储未注册客户
ALTER TABLE client_relations DROP CONSTRAINT IF EXISTS client_relations_client_id_fkey;

ALTER TABLE client_relations
  ADD CONSTRAINT client_relations_client_id_fkey
  FOREIGN KEY (client_id) REFERENCES profiles(id) ON DELETE CASCADE;
