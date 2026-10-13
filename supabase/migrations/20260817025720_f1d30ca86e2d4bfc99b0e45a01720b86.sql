CREATE TABLE IF NOT EXISTS public.help_faqs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope           text NOT NULL CHECK (scope IN ('platform','merchant')),
  root_manager_id uuid REFERENCES public.managers(id) ON DELETE CASCADE,
  audience        text NOT NULL CHECK (audience IN ('user','manager')),
  question        text NOT NULL,
  answer          text NOT NULL,
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.help_faqs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.help_faqs FROM anon, authenticated;
CREATE INDEX IF NOT EXISTS help_faqs_platform_audience ON public.help_faqs (audience, sort_order, id) WHERE scope = 'platform';
CREATE INDEX IF NOT EXISTS help_faqs_merchant_audience ON public.help_faqs (root_manager_id, audience, sort_order, id) WHERE root_manager_id IS NOT NULL;