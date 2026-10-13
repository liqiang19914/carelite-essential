CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS public.enterprise_qa_faqs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_id UUID NOT NULL REFERENCES public.enterprises(id) ON DELETE CASCADE,
  question TEXT NOT NULL CHECK (btrim(question) <> ''),
  answer TEXT NOT NULL CHECK (btrim(answer) <> ''),
  keywords TEXT[] NOT NULL DEFAULT '{}',
  source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','calibration','import')),
  source_message_id UUID,
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_enterprise_qa_faqs_ent_enabled
  ON public.enterprise_qa_faqs (enterprise_id, enabled);
CREATE INDEX IF NOT EXISTS idx_enterprise_qa_faqs_keywords
  ON public.enterprise_qa_faqs USING GIN (keywords);
CREATE INDEX IF NOT EXISTS idx_enterprise_qa_faqs_question_trgm
  ON public.enterprise_qa_faqs USING GIN (question gin_trgm_ops);

ALTER TABLE public.enterprise_qa_faqs ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.enterprise_qa_calibrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_id UUID NOT NULL REFERENCES public.enterprises(id) ON DELETE CASCADE,
  session_id UUID NOT NULL REFERENCES public.manager_public_qa_sessions(id) ON DELETE CASCADE,
  message_id UUID NOT NULL REFERENCES public.manager_public_qa_messages(id) ON DELETE CASCADE UNIQUE,
  manager_id UUID NOT NULL,
  question TEXT NOT NULL,
  ai_answer TEXT NOT NULL,
  correct_answer TEXT NOT NULL CHECK (btrim(correct_answer) <> ''),
  faq_id UUID,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_enterprise_qa_calibrations_ent
  ON public.enterprise_qa_calibrations (enterprise_id, created_at DESC);

ALTER TABLE public.enterprise_qa_calibrations ENABLE ROW LEVEL SECURITY;