-- 重置用户 15001230150 的密码为 123456
UPDATE auth.users 
SET encrypted_password = crypt('123456', gen_salt('bf')),
    updated_at = now()
WHERE id = '477ffa51-fa1f-42ca-9944-745bb7a8d971';