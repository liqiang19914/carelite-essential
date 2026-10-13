select set_config('request.jwt.claims', json_build_object('sub', '477ffa51-fa1f-42ca-9944-745bb7a8d971', 'role', 'authenticated')::text, true);
select public.add_client_follow_up(
  p_relation_id := 'f010b43c-8f63-45de-bd25-7f23bb49b4ec',
  p_content := '扫描服务联调测试',
  p_follow_up_type := '电话',
  p_next_follow_up_at := now() - interval '1 hour',
  p_reminder := true
);