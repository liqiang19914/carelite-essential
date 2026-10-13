ALTER TABLE manager_knowledge_documents
  DROP CONSTRAINT manager_knowledge_documents_status_check;

ALTER TABLE manager_knowledge_documents
  ADD CONSTRAINT manager_knowledge_documents_status_check
  CHECK (status IN ('uploading','parsing','indexing','ready','failed'));