-- ─────────────────────────────────────────────────────────────────────
-- 渠道短链：URL Scheme（外部浏览器自有域名唤起，不闪 wxmpurl.cn）
--
-- 背景：/go/<code> 之前一律 302 到微信 URL Link（wxmpurl.cn），浏览器地址栏
-- 会先露出微信域名。新增 URL Scheme（weixin://dl/business/?t=xxx）：
-- 自有域名页面 location.href 唤起微信，地址栏全程保持商户域名。
-- 微信内打开则用 <wx-open-launch-weapp> 开放标签（需服务号关联小程序）。
--
-- Scheme 与 URL Link 一样最长 30 天，缓存到渠道行，由 generate-miniapp-code
-- 的 urllink 模式一次性同时生成两者。
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.merchant_channels
  ADD COLUMN IF NOT EXISTS url_scheme text,
  ADD COLUMN IF NOT EXISTS url_scheme_expires_at timestamptz;

-- get_merchant_channel_for_code 现行版本是 plpgsql「SELECT * INTO v_row」
-- 的全字段版（20260910110000），新增列自动随 row_to_json 返回，无需重建。

CREATE OR REPLACE FUNCTION public.mark_merchant_channel_scheme(
  p_code text,
  p_url_scheme text,
  p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  UPDATE public.merchant_channels
  SET url_scheme = p_url_scheme,
      url_scheme_expires_at = p_expires_at
  WHERE code = p_code;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_merchant_channel_scheme(text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_merchant_channel_scheme(text, text, timestamptz) TO service_role;

NOTIFY pgrst, 'reload schema';
