-- Backfill Qiwe labels already stored in the raw contact payload.
INSERT INTO public.merchant_wecom_contact_tags
  (root_manager_id, external_userid, tag_id)
SELECT DISTINCT
  c.root_manager_id,
  c.external_userid,
  btrim(label ->> 'labelId')
FROM public.wecom_super_contacts c
CROSS JOIN LATERAL jsonb_array_elements(
  CASE
    WHEN jsonb_typeof(c.raw -> 'labelList') = 'array' THEN c.raw -> 'labelList'
    ELSE '[]'::jsonb
  END
) AS label
WHERE NULLIF(btrim(label ->> 'labelId'), '') IS NOT NULL
ON CONFLICT (root_manager_id, external_userid, tag_id) DO NOTHING;
