WITH s AS (
  SELECT set_config('request.jwt.claims',
    '{"sub":"477ffa51-fa1f-42ca-9944-745bb7a8d971","role":"authenticated"}', true) AS c
)
SELECT t.ticket IS NOT NULL AS 票据已签发
FROM s, public.create_measure_ticket(
  '70a1e80f-f8db-4d58-afcc-33920f89dbc6'::uuid,
  'picooc_scale',
  '5424dfb1-f528-436c-bd75-2028e3c2e286'::uuid
) t;