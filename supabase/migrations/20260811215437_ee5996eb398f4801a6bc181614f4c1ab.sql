WITH s AS (
  SELECT set_config('request.jwt.claims',
    '{"sub":"145548cf-6509-4eb4-9041-6c46b306b96a","role":"authenticated"}', true) AS c
)
SELECT public.merge_user_accounts(
  '9ce459e5-35a4-4cab-b535-8902fd8f2b64'::uuid,
  '477ffa51-fa1f-42ca-9944-745bb7a8d971'::uuid,
  false
) AS merge_result
FROM s;