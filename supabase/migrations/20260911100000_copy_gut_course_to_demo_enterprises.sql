-- 将现有《胃肠健康管理养生班》原样复制到三个演示企业；源课程保持不变。
DO $demo$
DECLARE
  v_source public.enterprise_courses%ROWTYPE;
  v_target record;
BEGIN
  SELECT * INTO v_source
  FROM public.enterprise_courses
  WHERE title = '胃肠健康管理养生班'
  ORDER BY is_published DESC, updated_at DESC
  LIMIT 1;

  IF v_source.id IS NULL THEN
    RAISE EXCEPTION '未找到《胃肠健康管理养生班》，停止复制';
  END IF;
  IF (SELECT count(*) FROM public.enterprise_course_chapters WHERE course_id = v_source.id) <> 5 THEN
    RAISE EXCEPTION '源课程章节数不是 5，停止复制以免内容不完整';
  END IF;

  FOR v_target IN SELECT * FROM (VALUES
    ('9d20e001-cbd4-4153-84e5-01e5b58f041f'::uuid,'eb7e71d1-e2c1-4d75-87a8-d33f69b526fe'::uuid),
    ('c6cce001-3b13-40fc-befb-aa70594ebe3c'::uuid,'a97f266d-383a-4cc4-ab1c-5d8b91264a54'::uuid),
    ('bfb8e001-4c1c-43fc-bce0-fe18e0401b4e'::uuid,'72ae1cbc-ed74-4ffa-9a22-aa0ab23fe4f9'::uuid)
  ) AS targets(course_id, enterprise_id)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.enterprises WHERE id = v_target.enterprise_id) THEN
      RAISE EXCEPTION '演示企业 % 不存在，停止复制', v_target.enterprise_id;
    END IF;

    INSERT INTO public.enterprise_courses (
      id,enterprise_id,category_id,title,cover_image_url,description,duration_minutes,
      is_published,sort_weight,study_count,like_count
    ) VALUES (
      v_target.course_id,v_target.enterprise_id,NULL,v_source.title,v_source.cover_image_url,
      v_source.description,v_source.duration_minutes,true,1000,v_source.study_count,v_source.like_count
    )
    ON CONFLICT (id) DO UPDATE SET
      category_id=NULL,title=EXCLUDED.title,cover_image_url=EXCLUDED.cover_image_url,
      description=EXCLUDED.description,duration_minutes=EXCLUDED.duration_minutes,
      is_published=true,sort_weight=1000,updated_at=now();

    DELETE FROM public.enterprise_course_chapters WHERE course_id = v_target.course_id;
    INSERT INTO public.enterprise_course_chapters (
      course_id,sort_order,title,intro,duration_seconds,video_url,video_storage_key,
      video_source,cover_url,is_free_preview
    )
    SELECT
      v_target.course_id,sort_order,title,intro,duration_seconds,video_url,video_storage_key,
      video_source,cover_url,is_free_preview
    FROM public.enterprise_course_chapters
    WHERE course_id = v_source.id
    ORDER BY sort_order;
  END LOOP;
END
$demo$;
