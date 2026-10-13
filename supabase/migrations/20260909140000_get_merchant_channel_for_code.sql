-- 渠道推广：供 Edge Function 读取单个渠道元信息（只读）。
-- 用途：
--   1) merchant-channel-track 的 /go 跳转：校验渠道是否投放中；
--   2) generate-miniapp-code 生成渠道码：校验渠道 + 取 root_manager_id 做鉴权与凭证解析。
-- 背景：EF 直连新建表 merchant_channels 在网关上不稳定（REST 直连 500），
--       统一收敛到 SECURITY DEFINER RPC（与列表/埋点/归因一致），EF 不直连表。
-- 仅 service_role（可信后端 EF）可执行；不向 anon/authenticated 暴露。
create or replace function public.get_merchant_channel_for_code(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(t)
  from (
    select c.code,
           c.root_manager_id,
           c.is_active,
           c.target_page
    from public.merchant_channels c
    where c.code = p_code
    limit 1
  ) t;
$$;

revoke all on function public.get_merchant_channel_for_code(text) from public;
grant execute on function public.get_merchant_channel_for_code(text) to service_role;
