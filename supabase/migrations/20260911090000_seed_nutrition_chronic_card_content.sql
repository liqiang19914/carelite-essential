-- 两个演示企业：补齐公开名片的精选商品、课程和封面。
DO $demo$
DECLARE
  v_nutrition CONSTANT uuid := 'c6cc187c-3b13-40fc-befb-aa70594ebe3c';
  v_chronic CONSTANT uuid := 'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e';
  v_nutrition_assessment CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/nutrition-assessment.png';
  v_nutrition_family CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/family-nutrition.png';
  v_nutrition_sport CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/sports-nutrition.png';
  v_chronic_bp CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/blood-pressure.png';
  v_chronic_glucose CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/glucose-followup.png';
  v_chronic_life CONSTANT text := 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/lifestyle-followup.png';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_nutrition)
     OR NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_chronic) THEN
    RAISE EXCEPTION '营养或慢病演示账号不存在，停止写入';
  END IF;

  UPDATE public.products SET
    cover_image_url = CASE
      WHEN owner_manager_id = v_nutrition AND title ~ '孕|儿童|术后' THEN v_nutrition_family
      WHEN owner_manager_id = v_nutrition AND title ~ '膳食|FODMAP|痛风' THEN v_nutrition_assessment
      WHEN owner_manager_id = v_nutrition THEN v_nutrition_sport
      WHEN owner_manager_id = v_chronic AND title ~ '血压' THEN v_chronic_bp
      WHEN owner_manager_id = v_chronic AND title ~ '血糖' THEN v_chronic_glucose
      ELSE v_chronic_life
    END,
    sort_weight = 700 - 100 * row_number_value,
    updated_at = now()
  FROM (
    SELECT id, row_number() OVER (PARTITION BY owner_manager_id ORDER BY created_at, id) AS row_number_value
    FROM public.products
    WHERE owner_manager_id IN (v_nutrition, v_chronic)
  ) ranked
  WHERE public.products.id = ranked.id;

  UPDATE public.managers m SET
    featured_product_ids = ARRAY(
      SELECT p.id FROM public.products p
      WHERE p.owner_manager_id = m.id
      ORDER BY p.sort_weight DESC, p.created_at
      LIMIT 6
    ),
    is_example = true,
    updated_at = now()
  WHERE m.id IN (v_nutrition, v_chronic);

  INSERT INTO public.manager_courses
    (id,manager_id,title,cover_image_url,description,duration_minutes,chapters,is_published,sort_weight,review_status,review_note,reviewed_at,visibility)
  VALUES
    ('c6cc1001-3b13-40fc-befb-aa70594ebe3c',v_nutrition,'读懂饮食记录：找到真正需要调整的一餐',v_nutrition_assessment,'从三日饮食记录中识别结构、份量与进食节律问题。',36,'[]',true,300,'approved','演示课程',now(),'public'),
    ('c6cc1002-3b13-40fc-befb-aa70594ebe3c',v_nutrition,'家庭营养餐盘：一桌饭兼顾不同年龄',v_nutrition_family,'用基础餐盘和份量调整，兼顾儿童、成人与长者的日常营养。',42,'[]',true,200,'approved','演示课程',now(),'public'),
    ('c6cc1003-3b13-40fc-befb-aa70594ebe3c',v_nutrition,'吃训协同：运动前后的营养安排',v_nutrition_sport,'根据训练类型和时长安排碳水、蛋白质与补水。',39,'[]',true,100,'approved','演示课程',now(),'public'),
    ('bfb81001-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,'家庭血压管理：从规范测量到趋势复盘',v_chronic_bp,'掌握家庭测量要点，用周趋势准备更有效的复诊沟通。',38,'[]',true,300,'approved','演示课程',now(),'public'),
    ('bfb81002-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,'看懂血糖波动：饮食、活动与监测',v_chronic_glucose,'记录关键时点，理解餐食和活动对血糖趋势的影响。',45,'[]',true,200,'approved','演示课程',now(),'public'),
    ('bfb81003-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,'长期管理行动课：用药、复查与生活习惯',v_chronic_life,'把医嘱、家庭监测和生活方式安排进可持续的日常计划。',40,'[]',true,100,'approved','演示课程',now(),'public')
  ON CONFLICT (id) DO UPDATE SET
    title=EXCLUDED.title,cover_image_url=EXCLUDED.cover_image_url,description=EXCLUDED.description,
    duration_minutes=EXCLUDED.duration_minutes,sort_weight=EXCLUDED.sort_weight,visibility='public',updated_at=now();

  DELETE FROM public.manager_course_chapters
  WHERE course_id IN (
    'c6cc1001-3b13-40fc-befb-aa70594ebe3c','c6cc1002-3b13-40fc-befb-aa70594ebe3c','c6cc1003-3b13-40fc-befb-aa70594ebe3c',
    'bfb81001-4c1c-43fc-bce0-fe18e0401b4e','bfb81002-4c1c-43fc-bce0-fe18e0401b4e','bfb81003-4c1c-43fc-bce0-fe18e0401b4e'
  );

  INSERT INTO public.manager_course_chapters
    (course_id,sort_order,title,intro,duration_seconds,video_source,cover_url,is_free_preview,is_active)
  VALUES
    ('c6cc1001-3b13-40fc-befb-aa70594ebe3c',0,'记录什么才有用','用三天记录还原真实进食节律。',660,'embed',v_nutrition_assessment,true,true),
    ('c6cc1001-3b13-40fc-befb-aa70594ebe3c',1,'看结构而不是算得很细','先识别蔬菜、蛋白质和主食结构。',720,'embed',v_nutrition_assessment,false,true),
    ('c6cc1001-3b13-40fc-befb-aa70594ebe3c',2,'一次只改一个关键点','把发现转化为一周可执行目标。',780,'embed',v_nutrition_assessment,false,true),
    ('c6cc1002-3b13-40fc-befb-aa70594ebe3c',0,'家庭餐盘的共同底座','建立全家都适用的基础搭配。',720,'embed',v_nutrition_family,true,true),
    ('c6cc1002-3b13-40fc-befb-aa70594ebe3c',1,'不同年龄怎样调整份量','按成长、活动和健康情况微调。',840,'embed',v_nutrition_family,false,true),
    ('c6cc1002-3b13-40fc-befb-aa70594ebe3c',2,'一周采购与备餐','用简单清单降低每天决策负担。',840,'embed',v_nutrition_family,false,true),
    ('c6cc1003-3b13-40fc-befb-aa70594ebe3c',0,'训练前怎么吃','根据距离训练的时间安排餐食。',720,'embed',v_nutrition_sport,true,true),
    ('c6cc1003-3b13-40fc-befb-aa70594ebe3c',1,'训练后恢复三件事','补水、碳水和蛋白质协同恢复。',780,'embed',v_nutrition_sport,false,true),
    ('c6cc1003-3b13-40fc-befb-aa70594ebe3c',2,'休息日也要有结构','用周期视角平衡训练与恢复。',840,'embed',v_nutrition_sport,false,true),
    ('bfb81001-4c1c-43fc-bce0-fe18e0401b4e',0,'家庭血压如何规范测','姿势、袖带和静息时间的基本要求。',720,'embed',v_chronic_bp,true,true),
    ('bfb81001-4c1c-43fc-bce0-fe18e0401b4e',1,'单次读数与一周趋势','减少对偶然波动的误判。',780,'embed',v_chronic_bp,false,true),
    ('bfb81001-4c1c-43fc-bce0-fe18e0401b4e',2,'带着记录去复诊','整理症状、用药和监测信息。',780,'embed',v_chronic_bp,false,true),
    ('bfb81002-4c1c-43fc-bce0-fe18e0401b4e',0,'血糖记录关键时点','理解空腹和餐后记录的用途。',720,'embed',v_chronic_glucose,true,true),
    ('bfb81002-4c1c-43fc-bce0-fe18e0401b4e',1,'把餐食与活动放在一起看','寻找可重复验证的生活影响因素。',840,'embed',v_chronic_glucose,false,true),
    ('bfb81002-4c1c-43fc-bce0-fe18e0401b4e',2,'低血糖风险怎么应对','识别警示信号并遵循医生预案。',840,'embed',v_chronic_glucose,false,true),
    ('bfb81003-4c1c-43fc-bce0-fe18e0401b4e',0,'建立个人管理清单','把医嘱、药物和复查节点放进日历。',720,'embed',v_chronic_life,true,true),
    ('bfb81003-4c1c-43fc-bce0-fe18e0401b4e',1,'从最小生活行动开始','选择低盐、步行或睡眠中的一个起点。',780,'embed',v_chronic_life,false,true),
    ('bfb81003-4c1c-43fc-bce0-fe18e0401b4e',2,'每周复盘，不自行改药','根据趋势准备与医疗团队沟通的问题。',900,'embed',v_chronic_life,false,true);

  -- 章节写入会触发重新审核，最后统一恢复演示课程的公开审核状态。
  UPDATE public.manager_courses SET
    is_published=true,review_status='approved',review_note='演示课程',reviewed_at=now(),visibility='public',updated_at=now()
  WHERE manager_id IN (v_nutrition,v_chronic)
    AND id IN (
      'c6cc1001-3b13-40fc-befb-aa70594ebe3c','c6cc1002-3b13-40fc-befb-aa70594ebe3c','c6cc1003-3b13-40fc-befb-aa70594ebe3c',
      'bfb81001-4c1c-43fc-bce0-fe18e0401b4e','bfb81002-4c1c-43fc-bce0-fe18e0401b4e','bfb81003-4c1c-43fc-bce0-fe18e0401b4e'
    );
END
$demo$;
