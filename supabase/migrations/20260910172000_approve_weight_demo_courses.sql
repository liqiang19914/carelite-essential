-- 章节写入触发器会把课程退回草稿；演示课程写完章节后统一恢复为已审核公开。
UPDATE public.manager_courses
SET review_status = 'approved',
    review_note = '演示课程',
    reviewed_at = now(),
    is_published = true,
    updated_at = now()
WHERE id IN (
  '9d20c001-cbd4-4153-84e5-01e5b58f041f',
  '9d20c002-cbd4-4153-84e5-01e5b58f041f',
  '9d20c003-cbd4-4153-84e5-01e5b58f041f'
);
