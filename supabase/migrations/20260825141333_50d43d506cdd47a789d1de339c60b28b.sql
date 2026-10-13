REVOKE EXECUTE ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) FROM anon;
REVOKE EXECUTE ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.calibrate_qa_answer(UUID, TEXT) FROM anon;
REVOKE EXECUTE ON FUNCTION public.delete_enterprise_qa_faq(UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION public.batch_import_enterprise_qa_faqs(JSONB) FROM anon;
REVOKE EXECUTE ON FUNCTION public.list_enterprise_qa_sessions(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_enterprise_qa_session(UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION public.list_enterprise_qa_faqs(TEXT, INTEGER, INTEGER) FROM anon;