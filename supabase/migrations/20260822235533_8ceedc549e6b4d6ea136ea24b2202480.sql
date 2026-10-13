create or replace function public.list_store_members(p_store_id uuid)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.store_members m
    where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active'
  ) then
    raise exception '你没有查看这家门店成员的权限' using errcode = '42501';
  end if;

  select json_agg(t order by t.created_at asc) into v_items
  from (
    select m.id, m.user_id, m.role, m.status, m.created_at,
           p.nickname, p.avatar_url, p.phone
    from public.store_members m
    join public.profiles p on p.id = m.user_id
    where m.store_id = p_store_id
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

create or replace function public.add_store_member(p_store_id uuid, p_user_id uuid, p_role text default 'clerk')
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text := coalesce(p_role, 'clerk');
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  if v_role not in ('owner','admin','clerk') then
    raise exception '成员角色不正确' using errcode = '22023';
  end if;
  if v_role = 'owner' then
    raise exception '店主只能由门店认领产生' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.store_members m
    where m.store_id = p_store_id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) then
    raise exception '只有店主或管理员才能添加成员' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception '这个用户不存在' using errcode = '22023';
  end if;
  if p_user_id = v_uid then
    raise exception '不能把自己添加成成员' using errcode = '22023';
  end if;

  insert into public.store_members (store_id, user_id, role, status, invited_by, created_at, updated_at)
  values (p_store_id, p_user_id, v_role, 'active', v_uid, now(), now())
  on conflict (store_id, user_id)
  do update set role = excluded.role, status = 'active', updated_at = now();

  return json_build_object('success', true);
end;
$function$;

create or replace function public.update_store_member(p_member_id uuid, p_role text, p_status text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_member public.store_members%rowtype;
  v_role text := coalesce(p_role, '');
  v_status text := coalesce(p_status, '');
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_member from public.store_members where id = p_member_id;
  if not found then
    raise exception '成员不存在' using errcode = '22023';
  end if;
  if v_member.role = 'owner' and v_member.user_id <> v_uid then
    raise exception '只有店主本人能变更自己的信息' using errcode = '42501';
  end if;
  if v_member.user_id = v_uid then
    raise exception '不能修改自己的角色和状态' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.store_members m
    where m.store_id = v_member.store_id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) then
    raise exception '只有店主或管理员才能管理成员' using errcode = '42501';
  end if;

  if v_role = '' then
    v_role := v_member.role;
  end if;
  if v_status = '' then
    v_status := v_member.status;
  end if;
  if v_role not in ('owner','admin','clerk') or v_status not in ('active','disabled') then
    raise exception '角色或状态不正确' using errcode = '22023';
  end if;
  if v_member.role in ('owner','admin') and v_role = 'clerk' then
    raise exception '店主和管理员不能降为店员' using errcode = '42501';
  end if;

  update public.store_members
     set role = v_role, status = v_status, updated_at = now()
   where id = v_member.id;

  return json_build_object('success', true);
end;
$function$;

create or replace function public.remove_store_member(p_member_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_member public.store_members%rowtype;
  v_caller_role text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_member from public.store_members where id = p_member_id;
  if not found then
    raise exception '成员不存在' using errcode = '22023';
  end if;
  if v_member.role = 'owner' then
    raise exception '店主不能被移除' using errcode = '42501';
  end if;

  select m.role into v_caller_role
  from public.store_members m
  where m.store_id = v_member.store_id and m.user_id = v_uid and m.status = 'active';
  if v_caller_role is null then
    raise exception '你不是这家门店的成员' using errcode = '42501';
  end if;
  if v_caller_role = 'clerk' then
    raise exception '店员不能移除成员' using errcode = '42501';
  end if;
  if v_caller_role = 'admin' and v_member.role = 'admin' then
    raise exception '管理员不能移除管理员' using errcode = '42501';
  end if;

  delete from public.store_members where id = v_member.id;

  return json_build_object('success', true);
end;
$function$;

grant execute on function public.list_store_members(uuid) to authenticated;
grant execute on function public.add_store_member(uuid, uuid, text) to authenticated;
grant execute on function public.update_store_member(uuid, text, text) to authenticated;
grant execute on function public.remove_store_member(uuid) to authenticated;