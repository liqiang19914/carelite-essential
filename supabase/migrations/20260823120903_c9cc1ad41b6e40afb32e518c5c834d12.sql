select set_config('request.jwt.claims', json_build_object('sub', 'b56561f7-fd93-45b8-bcbb-a764fadefad0', 'role', 'authenticated')::text, true);
select public.get_my_content_space() as space_before;
select public.save_reputation_section_name(p_name := '某某社区') as save_result;
select public.get_my_content_space() as space_after;