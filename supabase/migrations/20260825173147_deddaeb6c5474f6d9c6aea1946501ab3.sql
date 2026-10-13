BEGIN;
SET LOCAL ROLE service_role;
INSERT INTO public.manager_public_qa_sessions (manager_id, visitor_token, entry_source, first_message, message_count)
VALUES ('5424dfb1-f528-436c-bd75-2028e3c2e286', 'ddl-role-probe-1', 'public_qa', 'probe', 0)
RETURNING id;
ROLLBACK;