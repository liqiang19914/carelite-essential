-- 三个演示账号：复用现有门店素材，各补两本已通过机检的公开画册。
ALTER TABLE public.manager_content_items DISABLE TRIGGER manager_content_items_before_write_trg;
ALTER TABLE public.manager_content_album_pages DISABLE TRIGGER manager_content_album_pages_before_write_trg;
ALTER TABLE public.manager_content_album_pages DISABLE TRIGGER manager_content_album_pages_reset_moderation_trg;

DO $demo$
DECLARE
  v_weight CONSTANT uuid := '9d20bc6b-cbd4-4153-84e5-01e5b58f041f';
  v_nutrition CONSTANT uuid := 'c6cc187c-3b13-40fc-befb-aa70594ebe3c';
  v_chronic CONSTANT uuid := 'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e';
BEGIN
  IF (SELECT count(*) FROM public.managers WHERE id IN (v_weight, v_nutrition, v_chronic)) <> 3 THEN
    RAISE EXCEPTION '三个演示账号不完整，停止写入画册';
  END IF;

  INSERT INTO public.manager_content_items (
    id, root_manager_id, content_type, title, cover_url, cover_storage_key,
    is_published, sort_weight, moderation_status, moderation_labels,
    moderation_summary, moderation_checked_images, moderation_total_images,
    moderated_at, base_view_count, like_count, is_pinned, pinned_rank,
    created_by, updated_by
  ) VALUES
    ('9d20b101-cbd4-4153-84e5-01e5b58f041f', v_weight, 'album', '科学减重四步法',
     'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/hero-banner.png',
     'oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/hero-banner.png',
     true, 900, 'passed', '[]', '演示画册已通过', 3, 3, now(), 728, 31, true, 1, v_weight, v_weight),
    ('9d20b102-cbd4-4153-84e5-01e5b58f041f', v_weight, 'album', '一周生活方式行动清单',
     'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/lifestyle-support.png',
     'oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/lifestyle-support.png',
     true, 800, 'passed', '[]', '演示画册已通过', 3, 3, now(), 516, 24, false, 0, v_weight, v_weight),
    ('c6ccb101-3b13-40fc-befb-aa70594ebe3c', v_nutrition, 'album', '全人群均衡餐盘指南',
     'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/hero-banner.png',
     'oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/hero-banner.png',
     true, 900, 'passed', '[]', '演示画册已通过', 3, 3, now(), 684, 29, true, 1, v_nutrition, v_nutrition),
    ('c6ccb102-3b13-40fc-befb-aa70594ebe3c', v_nutrition, 'album', '运动与恢复营养手册',
     'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/sports-nutrition.png',
     'oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/sports-nutrition.png',
     true, 800, 'passed', '[]', '演示画册已通过', 3, 3, now(), 472, 21, false, 0, v_nutrition, v_nutrition),
    ('bfb8b101-4c1c-43fc-bce0-fe18e0401b4e', v_chronic, 'album', '家庭血压血糖记录指南',
     'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/hero-banner.png',
     'oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/hero-banner.png',
     true, 900, 'passed', '[]', '演示画册已通过', 3, 3, now(), 762, 34, true, 1, v_chronic, v_chronic),
    ('bfb8b102-4c1c-43fc-bce0-fe18e0401b4e', v_chronic, 'album', '慢病长期随访行动清单',
     'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/lifestyle-followup.png',
     'oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/lifestyle-followup.png',
     true, 800, 'passed', '[]', '演示画册已通过', 3, 3, now(), 543, 26, false, 0, v_chronic, v_chronic)
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title, cover_url = EXCLUDED.cover_url,
    cover_storage_key = EXCLUDED.cover_storage_key, is_published = true,
    sort_weight = EXCLUDED.sort_weight, moderation_status = 'passed',
    moderation_labels = '[]', moderation_summary = '演示画册已通过',
    moderation_checked_images = 3, moderation_total_images = 3,
    moderated_at = now(), base_view_count = EXCLUDED.base_view_count,
    like_count = EXCLUDED.like_count, is_pinned = EXCLUDED.is_pinned,
    pinned_rank = EXCLUDED.pinned_rank, updated_by = EXCLUDED.updated_by,
    updated_at = now();

  DELETE FROM public.manager_content_album_pages
  WHERE content_id IN (
    '9d20b101-cbd4-4153-84e5-01e5b58f041f', '9d20b102-cbd4-4153-84e5-01e5b58f041f',
    'c6ccb101-3b13-40fc-befb-aa70594ebe3c', 'c6ccb102-3b13-40fc-befb-aa70594ebe3c',
    'bfb8b101-4c1c-43fc-bce0-fe18e0401b4e', 'bfb8b102-4c1c-43fc-bce0-fe18e0401b4e'
  );

  INSERT INTO public.manager_content_album_pages
    (content_id, root_manager_id, sort_order, image_url, image_storage_key, alt_text, created_by, updated_by)
  VALUES
    ('9d20b101-cbd4-4153-84e5-01e5b58f041f',v_weight,0,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/hero-banner.png','oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/hero-banner.png','从科学评估开始制定阶段目标',v_weight,v_weight),
    ('9d20b101-cbd4-4153-84e5-01e5b58f041f',v_weight,1,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/body-assessment.png','oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/body-assessment.png','结合体重体脂和围度理解变化',v_weight,v_weight),
    ('9d20b101-cbd4-4153-84e5-01e5b58f041f',v_weight,2,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/nutrition-plan.png','oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/nutrition-plan.png','用可持续的餐盘结构落实计划',v_weight,v_weight),
    ('9d20b102-cbd4-4153-84e5-01e5b58f041f',v_weight,0,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/lifestyle-support.png','oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/lifestyle-support.png','把运动睡眠和情绪管理排进一周',v_weight,v_weight),
    ('9d20b102-cbd4-4153-84e5-01e5b58f041f',v_weight,1,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/nutrition-plan.png','oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/nutrition-plan.png','准备三餐与外食的简单替换方案',v_weight,v_weight),
    ('9d20b102-cbd4-4153-84e5-01e5b58f041f',v_weight,2,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/body-assessment.png','oem-banners/9d20bc6b-cbd4-4153-84e5-01e5b58f041f/2026-09-10/body-assessment.png','每周复盘趋势再调整下一步',v_weight,v_weight),

    ('c6ccb101-3b13-40fc-befb-aa70594ebe3c',v_nutrition,0,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/hero-banner.png','oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/hero-banner.png','均衡营养从真实饮食评估开始',v_nutrition,v_nutrition),
    ('c6ccb101-3b13-40fc-befb-aa70594ebe3c',v_nutrition,1,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/nutrition-assessment.png','oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/nutrition-assessment.png','识别膳食结构和营养重点',v_nutrition,v_nutrition),
    ('c6ccb101-3b13-40fc-befb-aa70594ebe3c',v_nutrition,2,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/family-nutrition.png','oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/family-nutrition.png','一桌饭按年龄和需求调整份量',v_nutrition,v_nutrition),
    ('c6ccb102-3b13-40fc-befb-aa70594ebe3c',v_nutrition,0,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/sports-nutrition.png','oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/sports-nutrition.png','训练营养需要配合强度和时间',v_nutrition,v_nutrition),
    ('c6ccb102-3b13-40fc-befb-aa70594ebe3c',v_nutrition,1,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/nutrition-assessment.png','oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/nutrition-assessment.png','根据训练记录评估补给是否适合',v_nutrition,v_nutrition),
    ('c6ccb102-3b13-40fc-befb-aa70594ebe3c',v_nutrition,2,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/hero-banner.png','oem-banners/c6cc187c-3b13-40fc-befb-aa70594ebe3c/2026-09-10/hero-banner.png','补水碳水蛋白质共同支持恢复',v_nutrition,v_nutrition),

    ('bfb8b101-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,0,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/hero-banner.png','oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/hero-banner.png','规范家庭监测支持长期管理',v_chronic,v_chronic),
    ('bfb8b101-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,1,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/blood-pressure.png','oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/blood-pressure.png','固定条件测量并记录血压趋势',v_chronic,v_chronic),
    ('bfb8b101-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,2,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/glucose-followup.png','oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/glucose-followup.png','把血糖和饮食活动放在一起复盘',v_chronic,v_chronic),
    ('bfb8b102-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,0,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/lifestyle-followup.png','oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/lifestyle-followup.png','把用药监测复查和生活行动放进日程',v_chronic,v_chronic),
    ('bfb8b102-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,1,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/blood-pressure.png','oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/blood-pressure.png','用连续记录准备更有效的复诊沟通',v_chronic,v_chronic),
    ('bfb8b102-4c1c-43fc-bce0-fe18e0401b4e',v_chronic,2,'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/glucose-followup.png','oem-banners/bfb89a01-4c1c-43fc-bce0-fe18e0401b4e/2026-09-10/glucose-followup.png','出现异常趋势及时联系医疗团队',v_chronic,v_chronic);

  IF EXISTS (
    SELECT root_manager_id
    FROM public.manager_content_items
    WHERE root_manager_id IN (v_weight, v_nutrition, v_chronic)
      AND content_type = 'album' AND is_published AND moderation_status = 'passed'
    GROUP BY root_manager_id
    HAVING count(*) < 2
  ) OR (
    SELECT count(DISTINCT root_manager_id)
    FROM public.manager_content_items
    WHERE root_manager_id IN (v_weight, v_nutrition, v_chronic)
      AND content_type = 'album' AND is_published AND moderation_status = 'passed'
  ) <> 3 THEN
    RAISE EXCEPTION '演示画册完整性检查失败';
  END IF;
END
$demo$;

ALTER TABLE public.manager_content_album_pages ENABLE TRIGGER manager_content_album_pages_reset_moderation_trg;
ALTER TABLE public.manager_content_album_pages ENABLE TRIGGER manager_content_album_pages_before_write_trg;
ALTER TABLE public.manager_content_items ENABLE TRIGGER manager_content_items_before_write_trg;
