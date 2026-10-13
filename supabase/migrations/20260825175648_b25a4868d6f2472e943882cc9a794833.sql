DROP FUNCTION IF EXISTS public.qa_verify_debug_claims();
DROP FUNCTION IF EXISTS public.qa_verify_debug_role();
DROP FUNCTION IF EXISTS public.qa_session_upsert_and_log(UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS public.qa_session_log_assistant(UUID, TEXT, JSONB, JSONB, JSONB);
DROP FUNCTION IF EXISTS public.qa_session_delete(UUID);