create or replace function public.save_reputation_section_name(
  p_name text,
  p_root_manager_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_name text := nullif(btrim(p_name), '');
  v_display text;
begin
  if v_uid is null then
    raise exception '请先登录后再保存' using errcode = '28000';
  end if;

  if char_length(coalesce(v_name, '')) > 30 then
    raise exception '用户发布板块名称最多 30 个字，请精简后重试' using errcode = '22023';
  end if;

  if public.is_admin(v_uid) then
    v_root := p_root_manager_id;
    if v_root is null
       or not exists (select 1 from public.managers where id = v_root) then
      raise exception '请选择有效企业' using errcode = '22023';
    end if;
  else
    if not public.is_active_enterprise_content_member(v_uid) then
      raise exception '所属企业当前不可修改板块名称，请联系企业负责人或平台处理'
        using errcode = '42501';
    end if;
    v_root := public.get_enterprise_root_manager_id(v_uid);
  end if;

  insert into public.manager_content_spaces (
    root_manager_id, reputation_name, created_by, updated_by
  )
  values (v_root, v_name, v_uid, v_uid)
  on conflict (root_manager_id) do update
    set reputation_name = excluded.reputation_name,
        updated_by = v_uid,
        updated_at = now();

  select nullif(btrim(display_name), '')
    into v_display
  from public.manager_content_spaces
  where root_manager_id = v_root;

  return jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', coalesce(v_display, '健康学堂'),
    'is_custom_name', v_display is not null,
    'reputation_name', coalesce(v_name, '达人口碑'),
    'is_custom_reputation_name', v_name is not null
  );
end;
$function$;