REVOKE EXECUTE ON FUNCTION public.list_enterprise_reputation_comments(uuid, integer, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.merchant_create_reputation_comment(uuid, text, text, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.delete_reputation_comment(uuid) FROM anon;