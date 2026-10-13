-- 企业微信应用消息闭环：
-- 员工( profiles )绑定企微 userid → 跟进到期时自建应用给跟进人发应用消息。
-- 绑定来源：手机号匹配（user/getuserid）+ 回调事件被动匹配（FromUserName 反查），
-- 两者都写 profiles.wecom_userid；access_token 缓存在 merchant_wecom_settings。

-- ① 员工企微绑定字段
alter table public.profiles
  add column if not exists wecom_userid text,
  add column if not exists wecom_bound_at timestamptz;

comment on column public.profiles.wecom_userid is
  '企业微信成员 userid（自建应用通讯录匹配），用于应用消息推送';

-- ② 自建应用 access_token 缓存（约 2 小时有效，避免每次发消息都换 token）
alter table public.merchant_wecom_settings
  add column if not exists single_chat_access_token text,
  add column if not exists single_chat_token_expires_at timestamptz;

-- ③ 跟进提醒的企业微信通知开关
alter table public.follow_up_records
  add column if not exists reminder_wecom boolean not null default false;

-- ④ 记跟进：新增企业微信提醒参数
drop function if exists public.add_client_follow_up(uuid, text, text, timestamptz, boolean);
create or replace function public.add_client_follow_up(
  p_relation_id uuid,
  p_content text,
  p_follow_up_type text default null,
  p_next_follow_up_at timestamptz default null,
  p_reminder boolean default false,
  p_reminder_wecom boolean default false
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_rel public.client_relations%rowtype;
  v_root uuid;
  v_new_id uuid;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '28000';
  end if;
  if p_relation_id is null then
    raise exception '缺少客户信息' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_content, '')), '') is null then
    raise exception '请填写跟进内容' using errcode = '22023';
  end if;
  if coalesce(p_reminder, false) and p_next_follow_up_at is null then
    raise exception '开启提醒需要设置下次跟进时间' using errcode = '22023';
  end if;

  select * into v_rel
  from public.client_relations
  where id = p_relation_id;

  if v_rel.id is null then
    raise exception '未找到该客户' using errcode = '22023';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  if v_rel.manager_id is distinct from v_uid
     and not (
       public.is_enterprise_admin(v_uid)
       and v_rel.root_manager_id is not distinct from v_root
     ) then
    raise exception '只能为自己负责的客户记跟进' using errcode = '42501';
  end if;

  insert into public.follow_up_records
    (client_relation_id, content, follow_up_type, next_follow_up_at, reminder, reminder_wecom, created_by)
  values
    (p_relation_id, btrim(p_content), nullif(btrim(coalesce(p_follow_up_type, '')), ''),
     p_next_follow_up_at, coalesce(p_reminder, false), coalesce(p_reminder_wecom, false), v_uid)
  returning id into v_new_id;

  update public.client_relations
     set last_contact_at = now(), updated_at = now()
   where id = p_relation_id;

  return v_new_id;
end;
$function$;

-- ⑤ 修改跟进提醒：支持企业微信提醒参数
drop function if exists public.update_follow_up_reminder(uuid, text, text, timestamptz, boolean);
create or replace function public.update_follow_up_reminder(
  p_record_id uuid,
  p_content text default null,
  p_follow_up_type text default null,
  p_next_follow_up_at timestamptz default null,
  p_reminder boolean default null,
  p_reminder_wecom boolean default null
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_rec record;
  v_root uuid;
  v_new_reminder boolean;
  v_new_next timestamptz;
  v_time_changed boolean;
  v_reset_reminded boolean := false;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '28000';
  end if;
  if p_record_id is null then
    raise exception '缺少跟进记录' using errcode = '22023';
  end if;

  select fr.reminder, fr.next_follow_up_at,
         cr.manager_id, cr.root_manager_id
    into v_rec
  from public.follow_up_records fr
  join public.client_relations cr on cr.id = fr.client_relation_id
  where fr.id = p_record_id;

  if v_rec.root_manager_id is null then
    raise exception '未找到该跟进记录' using errcode = '22023';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  if v_rec.manager_id is distinct from v_uid
     and not (
       public.is_enterprise_admin(v_uid)
       and v_rec.root_manager_id is not distinct from v_root
     ) then
    raise exception '只能修改自己负责客户的跟进记录' using errcode = '42501';
  end if;

  v_new_reminder := coalesce(p_reminder, v_rec.reminder);
  v_new_next := p_next_follow_up_at;
  v_time_changed := (p_next_follow_up_at is distinct from v_rec.next_follow_up_at);

  if v_new_reminder and v_new_next is null then
    raise exception '开启提醒需要设置下次跟进时间' using errcode = '22023';
  end if;

  if v_new_reminder and (coalesce(p_reminder, false) or v_time_changed) then
    v_reset_reminded := true;
  end if;

  update public.follow_up_records
     set content = coalesce(p_content, content),
         follow_up_type = coalesce(nullif(btrim(coalesce(p_follow_up_type, '')), ''), follow_up_type),
         next_follow_up_at = v_new_next,
         reminder = v_new_reminder,
         reminder_wecom = coalesce(p_reminder_wecom, reminder_wecom),
         reminded_at = case when v_reset_reminded then null else reminded_at end
   where id = p_record_id;

  return true;
end;
$function$;

-- ⑥ 权限
grant execute on function public.add_client_follow_up(uuid, text, text, timestamptz, boolean, boolean) to authenticated;
grant execute on function public.update_follow_up_reminder(uuid, text, text, timestamptz, boolean, boolean) to authenticated;
