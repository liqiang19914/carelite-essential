INSERT INTO vital_signs (record_id, recorded_at, heart_rate, systolic_pressure, diastolic_pressure, blood_sugar, temperature, weight, notes)
SELECT
  '06e6ab15-6bb4-4e9f-94c1-a00c1a111cc0'::uuid,
  now() - make_interval(days => d) - make_interval(hours => (random()*12)::int),
  greatest(63, least(82, round(72 + 5*sin(d*0.35) + (random()*8 - 4))::int)),
  greatest(124, least(145, round(134 + 5*sin(d*0.18) + (random()*8 - 4))::int)),
  greatest(78, least(93, round(85 + 3*sin(d*0.22) + (random()*5 - 2.5))::int)),
  greatest(4.9, least(6.3, round((5.6 + 0.35*sin(d*0.27) + (random()*0.5 - 0.25))::numeric, 1))),
  greatest(36.2, least(37.0, round((36.6 + 0.15*sin(d*0.4) + (random()*0.25 - 0.125))::numeric, 1))),
  greatest(84.0, least(87.0, round((84.7 + (d/365.0)*1.6 + (random()*0.6 - 0.3))::numeric, 1))),
  '示例数据'
FROM (
  SELECT generate_series(0, 7, 1) AS d
  UNION SELECT generate_series(9, 30, 2)
  UNION SELECT generate_series(34, 90, 4)
  UNION SELECT generate_series(97, 365, 7)
) AS days;