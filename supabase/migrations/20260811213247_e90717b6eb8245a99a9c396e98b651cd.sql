CREATE OR REPLACE FUNCTION public.normalize_cn_phone(raw text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN d ~ '^1[3-9][0-9]{9}$' THEN d ELSE '' END
  FROM (
    SELECT regexp_replace(regexp_replace(coalesce(raw, ''), '[^0-9]', '', 'g'), '^(86)+', '') AS d
  ) t;
$$;