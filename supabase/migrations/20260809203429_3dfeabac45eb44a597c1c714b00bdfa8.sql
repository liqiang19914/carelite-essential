ALTER TABLE public.body_compositions
  DROP CONSTRAINT body_compositions_origin_check;

ALTER TABLE public.body_compositions
  ADD CONSTRAINT body_compositions_origin_check
  CHECK (origin = ANY (ARRAY['live'::text, 'cached'::text, 'manual'::text, 'imported'::text]));