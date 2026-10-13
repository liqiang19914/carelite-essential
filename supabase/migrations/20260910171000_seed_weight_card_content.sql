-- 轻盈体重管理工作室：补齐公开名片里的主推产品、课程和内容板块。
ALTER TABLE public.manager_content_items DISABLE TRIGGER manager_content_items_before_write_trg;

DO $demo$
DECLARE
  v_root CONSTANT uuid := '9d20bc6b-cbd4-4153-84e5-01e5b58f041f';
  v_body CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/body-assessment.png';
  v_food CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/nutrition-plan.png';
  v_life CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/lifestyle-support.png';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_root) THEN
    RAISE EXCEPTION '轻盈体重管理演示账号不存在，停止写入';
  END IF;

  UPDATE public.managers SET is_example = true, updated_at = now() WHERE id = v_root;

  UPDATE public.products SET sort_weight = CASE id
    WHEN '977bb747-de12-4f6c-ab97-0135a50a2474'::uuid THEN 600
    WHEN '7288a851-4fc1-47d2-9b2a-f931fa3b8cc5'::uuid THEN 500
    WHEN '62033789-4e75-48d6-8592-224fa2d6578f'::uuid THEN 400
    WHEN 'b4a6253b-7ab5-42d5-9744-08b51d467017'::uuid THEN 300
    WHEN '797d0b28-eaba-459b-9acb-c208a147ec29'::uuid THEN 200
    ELSE 100 END
  WHERE owner_manager_id = v_root;

  UPDATE public.managers SET featured_product_ids = ARRAY[
    '977bb747-de12-4f6c-ab97-0135a50a2474'::uuid,
    '7288a851-4fc1-47d2-9b2a-f931fa3b8cc5'::uuid,
    '62033789-4e75-48d6-8592-224fa2d6578f'::uuid,
    'b4a6253b-7ab5-42d5-9744-08b51d467017'::uuid,
    '797d0b28-eaba-459b-9acb-c208a147ec29'::uuid,
    '7e60bf40-5707-4048-a958-b68dbe9a6112'::uuid
  ], updated_at = now() WHERE id = v_root;

  INSERT INTO public.manager_courses
    (id,manager_id,title,cover_image_url,description,duration_minutes,chapters,is_published,sort_weight,review_status,review_note,reviewed_at,visibility)
  VALUES
    ('9d20c001-cbd4-4153-84e5-01e5b58f041f',v_root,'看懂体重波动：从单日数字到七日趋势',v_body,'学会识别水分、盐分、经期与作息带来的短期波动，建立科学复盘方法。',32,'[]',true,300,'approved','演示课程',now(),'public'),
    ('9d20c002-cbd4-4153-84e5-01e5b58f041f',v_root,'减脂餐盘实操：外食也能吃得有结构',v_food,'用餐盘比例、份量估算和点餐顺序，把营养方案落实到日常三餐。',45,'[]',true,200,'approved','演示课程',now(),'public'),
    ('9d20c003-cbd4-4153-84e5-01e5b58f041f',v_root,'21天习惯养成：饮食、运动与睡眠',v_life,'从最小行动开始，建立能够长期坚持的饮食、活动和睡眠节律。',38,'[]',true,100,'approved','演示课程',now(),'public')
  ON CONFLICT (id) DO UPDATE SET
    title=EXCLUDED.title,cover_image_url=EXCLUDED.cover_image_url,description=EXCLUDED.description,
    duration_minutes=EXCLUDED.duration_minutes,is_published=true,sort_weight=EXCLUDED.sort_weight,
    review_status='approved',review_note='演示课程',reviewed_at=now(),visibility='public',updated_at=now();

  DELETE FROM public.manager_course_chapters
  WHERE course_id IN (
    '9d20c001-cbd4-4153-84e5-01e5b58f041f','9d20c002-cbd4-4153-84e5-01e5b58f041f','9d20c003-cbd4-4153-84e5-01e5b58f041f'
  );
  INSERT INTO public.manager_course_chapters
    (course_id,sort_order,title,intro,duration_seconds,video_source,cover_url,is_free_preview,is_active)
  VALUES
    ('9d20c001-cbd4-4153-84e5-01e5b58f041f',0,'为什么一天会重一公斤','认识糖原、水分、盐分与排便的影响。',600,'embed',v_body,true,true),
    ('9d20c001-cbd4-4153-84e5-01e5b58f041f',1,'用七日均值看真实趋势','建立不被单日数字影响的复盘方式。',660,'embed',v_body,false,true),
    ('9d20c001-cbd4-4153-84e5-01e5b58f041f',2,'体重停滞期怎么判断','从围度、执行率和时间跨度综合判断。',660,'embed',v_body,false,true),
    ('9d20c002-cbd4-4153-84e5-01e5b58f041f',0,'一只餐盘的营养结构','掌握蔬菜、蛋白和主食的基础比例。',720,'embed',v_food,true,true),
    ('9d20c002-cbd4-4153-84e5-01e5b58f041f',1,'外卖点餐四步法','从烹调方式、主食份量和酱汁做选择。',900,'embed',v_food,false,true),
    ('9d20c002-cbd4-4153-84e5-01e5b58f041f',2,'聚餐后的温和调整','不补偿性节食，回到规律饮食和活动。',840,'embed',v_food,false,true),
    ('9d20c003-cbd4-4153-84e5-01e5b58f041f',0,'找到自己的最小行动','选择能连续完成的饮食与活动目标。',660,'embed',v_life,true,true),
    ('9d20c003-cbd4-4153-84e5-01e5b58f041f',1,'睡眠不足为什么更想吃','识别疲劳、压力与食欲之间的关系。',780,'embed',v_life,false,true),
    ('9d20c003-cbd4-4153-84e5-01e5b58f041f',2,'失败一天不等于失败','用下一餐和下一次行动快速回归节奏。',840,'embed',v_life,false,true);

  INSERT INTO public.manager_content_spaces (root_manager_id,display_name,created_by,updated_by)
  VALUES (v_root,'轻盈减重课堂',v_root,v_root)
  ON CONFLICT (root_manager_id) DO UPDATE SET display_name=EXCLUDED.display_name,updated_by=v_root,updated_at=now();

  INSERT INTO public.manager_content_items
    (id,root_manager_id,content_type,title,cover_url,article_doc,is_published,sort_weight,moderation_status,
     moderation_labels,moderation_summary,moderated_at,created_by,updated_by)
  VALUES
    ('9d20a001-cbd4-4153-84e5-01e5b58f041f',v_root,'article','体重一天涨了1公斤，真的是胖了吗？',v_body,
     jsonb_build_object('type','doc','content',jsonb_build_array(jsonb_build_object('type','paragraph','content',jsonb_build_array(jsonb_build_object('type','text','text','多数单日波动来自水分、盐分、糖原、排便和经期变化。固定时间称重并观察七日趋势，比纠结某一天更有意义。'))))),true,500,'passed','[]','演示内容已通过',now(),v_root,v_root),
    ('9d20a002-cbd4-4153-84e5-01e5b58f041f',v_root,'article','外卖减脂不靠水煮：记住四个点餐顺序',v_food,
     jsonb_build_object('type','doc','content',jsonb_build_array(jsonb_build_object('type','paragraph','content',jsonb_build_array(jsonb_build_object('type','text','text','先选优质蛋白，再补足蔬菜，主食按需要定量，酱汁单放。稳定做到七八成，比追求每餐完美更容易长期坚持。'))))),true,400,'passed','[]','演示内容已通过',now(),v_root,v_root),
    ('9d20a003-cbd4-4153-84e5-01e5b58f041f',v_root,'article','减重平台期，先检查这五件事',v_body,
     jsonb_build_object('type','doc','content',jsonb_build_array(jsonb_build_object('type','paragraph','content',jsonb_build_array(jsonb_build_object('type','text','text','检查记录时间、执行一致性、睡眠压力、活动量和围度变化。连续两到四周趋势稳定，再考虑调整方案。'))))),true,300,'passed','[]','演示内容已通过',now(),v_root,v_root),
    ('9d20a004-cbd4-4153-84e5-01e5b58f041f',v_root,'article','晚上总想吃东西，可能不只是嘴馋',v_life,
     jsonb_build_object('type','doc','content',jsonb_build_array(jsonb_build_object('type','paragraph','content',jsonb_build_array(jsonb_build_object('type','text','text','晚餐结构不足、睡眠不足、压力和固定情境都可能触发进食。先记录一周触发时间，再针对原因做最小调整。'))))),true,200,'passed','[]','演示内容已通过',now(),v_root,v_root),
    ('9d20a005-cbd4-4153-84e5-01e5b58f041f',v_root,'article','一周运动怎么排，才更容易坚持？',v_life,
     jsonb_build_object('type','doc','content',jsonb_build_array(jsonb_build_object('type','paragraph','content',jsonb_build_array(jsonb_build_object('type','text','text','把日常步行、两到三次力量练习和喜欢的有氧活动组合起来，并为忙碌日准备十分钟备选方案。'))))),true,100,'passed','[]','演示内容已通过',now(),v_root,v_root)
  ON CONFLICT (id) DO UPDATE SET
    title=EXCLUDED.title,cover_url=EXCLUDED.cover_url,article_doc=EXCLUDED.article_doc,is_published=true,
    sort_weight=EXCLUDED.sort_weight,moderation_status='passed',moderation_labels='[]',
    moderation_summary='演示内容已通过',moderated_at=now(),updated_by=v_root,updated_at=now();
END
$demo$;

ALTER TABLE public.manager_content_items ENABLE TRIGGER manager_content_items_before_write_trg;
