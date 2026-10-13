CREATE OR REPLACE FUNCTION normalize_cn_phone(raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN regexp_replace(coalesce(raw, ''), '\D', '', 'g') ~ '^861[3-9]\d{9}$'
      THEN substring(regexp_replace(raw, '\D', '', 'g') from 3)
    WHEN regexp_replace(coalesce(raw, ''), '\D', '', 'g') ~ '^1[3-9]\d{9}$'
      THEN regexp_replace(raw, '\D', '', 'g')
    ELSE ''
  END;
$$;