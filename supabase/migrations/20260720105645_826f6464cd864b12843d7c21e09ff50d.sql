-- Project-wide convention: authenticated-only RPCs must explicitly revoke anon,
-- since Supabase's anon/authenticated roles do not inherit from PUBLIC's default policy.
-- RPC body already rejects anon (auth.uid() IS NULL check), this is defense in depth.
REVOKE EXECUTE ON FUNCTION public.update_my_privacy_setting(uuid, text, boolean) FROM anon;