DELETE FROM public.profiles WHERE nickname LIKE '访客验证%' AND phone LIKE '139%' AND id IN (
  SELECT p.id FROM public.profiles p
  LEFT JOIN auth.users u ON u.id = p.id
  WHERE u.id IS NULL AND p.nickname LIKE '访客验证%'
);