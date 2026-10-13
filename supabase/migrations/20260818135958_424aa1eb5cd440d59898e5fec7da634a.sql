-- 代员工编辑智能体名片：企业 RBAC 闸门 + 字段白名单
--
-- 背景：managers 表的行级策略只放行「直属老板改直属员工」，而企业「管理员」角色
-- 的员工 parent_manager_id 指向超管而不是他自己，所以管理员即使被勾选了
-- agent_edit 也读不到、改不了同事的名片。同时 authenticated 对 managers 的
-- 61 个列全部有 UPDATE 权限，直接放宽行策略等于把 membership_level /
-- seat_limit_override / brand_slug / invite_code 一起交出去。
-- 因此这里用 SECURITY DEFINER 函数收口：闸门与 Edge Function 里的
-- canManageTargetManager 保持同一套语义，可写列只有公开资料 6 项 + 主推产品。

create or replace function public.can_manage_target_manager_card(
  p_caller uuid,
  p_target uuid,
  p_permission_code text
) returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller_disabled boolean;
  v_caller_role text;
  v_caller_ent uuid;
  v_target_ent uuid;
begin
  if p_caller is null or p_target is null then
    return false;
  end if;

  select coalesce(is_disabled, false), role, enterprise_id
    into v_caller_disabled, v_caller_role, v_caller_ent
    from profiles where id = p_caller;
  if not found or v_caller_disabled then
    return false;
  end if;

  -- 本人始终可以（已禁用账号除外，上面已挡）
  if p_caller = p_target then
    return true;
  end if;

  if v_caller_role = 'admin' then
    return true;
  end if;

  select enterprise_id into v_target_ent from profiles where id = p_target;
  if not found or v_target_ent is null or v_caller_ent is null or v_target_ent <> v_caller_ent then
    return false;
  end if;

  return coalesce(has_enterprise_permission(p_permission_code, p_caller), false);
end
$function$;

revoke all on function public.can_manage_target_manager_card(uuid, uuid, text) from public;
grant execute on function public.can_manage_target_manager_card(uuid, uuid, text) to authenticated, service_role;

create or replace function public.get_target_manager_card(
  p_target_manager_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller uuid := auth.uid();
  v_row jsonb;
  v_nickname text;
begin
  if v_caller is null then
    raise exception '请先登录';
  end if;
  if not can_manage_target_manager_card(v_caller, p_target_manager_id, 'agent_edit') then
    raise exception '无权限查看该员工的智能体名片';
  end if;

  select to_jsonb(m) - 'business_license' - 'membership_note'
    into v_row
    from managers m
   where m.id = p_target_manager_id;
  if v_row is null then
    raise exception '该员工的健管师档案不存在';
  end if;

  select nickname into v_nickname from profiles where id = p_target_manager_id;
  return v_row || jsonb_build_object('profile_nickname', v_nickname);
end
$function$;

revoke all on function public.get_target_manager_card(uuid) from public;
grant execute on function public.get_target_manager_card(uuid) to authenticated;

create or replace function public.update_target_manager_card(
  p_target_manager_id uuid,
  p_patch jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller uuid := auth.uid();
  v_id uuid;
begin
  if v_caller is null then
    raise exception '请先登录';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception '没有要保存的内容';
  end if;
  if not can_manage_target_manager_card(v_caller, p_target_manager_id, 'agent_edit') then
    raise exception '无权限编辑该员工的智能体，请联系超级管理员在「企业中心 → 角色权限」里勾选';
  end if;

  -- 白名单外的键一律忽略：只开放公开资料与主推产品，会员档位 / 品牌路径 /
  -- 邀请码 / 知识库索引等字段绝不能被代编辑改到。
  update managers m
     set tagline = case when p_patch ? 'tagline'
                        then nullif(p_patch->>'tagline', '') else m.tagline end,
         intro_personal = case when p_patch ? 'intro_personal'
                        then nullif(p_patch->>'intro_personal', '') else m.intro_personal end,
         intro_company = case when p_patch ? 'intro_company'
                        then nullif(p_patch->>'intro_company', '') else m.intro_company end,
         company_name = case when p_patch ? 'company_name'
                        then nullif(p_patch->>'company_name', '') else m.company_name end,
         public_contact_phone = case when p_patch ? 'public_contact_phone'
                        then nullif(p_patch->>'public_contact_phone', '') else m.public_contact_phone end,
         credentials = case when p_patch ? 'credentials'
                        then (
                          select coalesce(array_agg(x.v order by x.ord), '{}'::text[])
                            from jsonb_array_elements_text(
                                   case when jsonb_typeof(p_patch->'credentials') = 'array'
                                        then p_patch->'credentials' else '[]'::jsonb end
                                 ) with ordinality as x(v, ord)
                        )
                        else m.credentials end,
         featured_product_ids = case when p_patch ? 'featured_product_ids'
                        then (
                          select coalesce(array_agg(x.v::uuid order by x.ord), '{}'::uuid[])
                            from jsonb_array_elements_text(
                                   case when jsonb_typeof(p_patch->'featured_product_ids') = 'array'
                                        then p_patch->'featured_product_ids' else '[]'::jsonb end
                                 ) with ordinality as x(v, ord)
                        )
                        else m.featured_product_ids end,
         updated_at = now()
   where m.id = p_target_manager_id
   returning m.id into v_id;

  if v_id is null then
    raise exception '该员工的健管师档案不存在，保存失败';
  end if;
  return v_id;
end
$function$;

revoke all on function public.update_target_manager_card(uuid, jsonb) from public;
grant execute on function public.update_target_manager_card(uuid, jsonb) to authenticated;