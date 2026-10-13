-- Fix: get_public_qa_config incorrectly referenced m.avatar_url and p.public_card_is_example
-- Restore original column mappings while keeping the new document count fields.
CREATE OR REPLACE FUNCTION public.get_public_qa_config(p_manager_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_manager managers%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_ready_count INT;
  v_parsing_count INT;
  v_failed_count INT;
  v_total_count INT;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = p_manager_id;

  SELECT
    COUNT(*) FILTER (WHERE status = 'ready'),
    COUNT(*) FILTER (WHERE status = 'parsing'),
    COUNT(*) FILTER (WHERE status = 'failed'),
    COUNT(*)
    INTO v_ready_count, v_parsing_count, v_failed_count, v_total_count
    FROM manager_knowledge_documents
   WHERE manager_id = p_manager_id;

  RETURN json_build_object(
    'manager_id', v_manager.id,
    'enabled', COALESCE(v_manager.public_qa_enabled, false),
    'welcome_message', v_manager.public_qa_welcome_message,
    'lead_capture_mode', COALESCE(v_manager.public_qa_lead_capture_mode, 'both'),
    'display_name', COALESCE(v_manager.partner_card_display_name, v_profile.nickname, '健康管理师'),
    'avatar_url', COALESCE(v_manager.digital_avatar_image_url, v_manager.partner_card_avatar_url, v_profile.avatar_url),
    'tagline', v_manager.tagline,
    'is_example', COALESCE(v_manager.is_example, false),
    'knowledge_index_status', COALESCE(v_manager.knowledge_index_status, 'none'),
    'ready_doc_count', COALESCE(v_ready_count, 0),
    'parsing_doc_count', COALESCE(v_parsing_count, 0),
    'failed_doc_count', COALESCE(v_failed_count, 0),
    'total_doc_count', COALESCE(v_total_count, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_qa_config(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_qa_config(UUID) TO anon, authenticated;