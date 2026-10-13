-- 渠道推广：Edge Function（service_role）需要读取渠道表
-- 用途：/go 短链跳转时校验渠道是否投放中、generate-miniapp-code 生成渠道码时鉴权。
-- 仅放开 SELECT（只读）；写操作（建/改/停用、埋点、归因、二维码回写）仍全部走
-- SECURITY DEFINER RPC，不向 service_role 放开 INSERT/UPDATE/DELETE。
-- events/signups 表 EF 不直连，全部经 track/attribute RPC，故不授权。
GRANT SELECT ON public.merchant_channels TO service_role;
