ALTER TABLE public.diet_map_assessments
  ADD COLUMN IF NOT EXISTS verdict jsonb;

ALTER TABLE public.diet_map_assessments
  DROP CONSTRAINT IF EXISTS diet_map_assessments_scored_needs_type;

ALTER TABLE public.diet_map_assessments
  ADD CONSTRAINT diet_map_assessments_scored_needs_type
  CHECK (
    status <> 'scored'
    OR type_code <> ''
    OR COALESCE((verdict ->> 'balanced')::boolean, false)
  );

ALTER TABLE public.diet_map_assessments
  DROP CONSTRAINT IF EXISTS diet_map_assessments_verdict_shape;

ALTER TABLE public.diet_map_assessments
  ADD CONSTRAINT diet_map_assessments_verdict_shape
  CHECK (
    verdict IS NULL
    OR (
      jsonb_typeof(verdict -> 'primary') = 'array'
      AND jsonb_typeof(verdict -> 'secondary') = 'array'
      AND jsonb_typeof(verdict -> 'balanced') = 'boolean'
    )
  );