-- ============================================================
-- 健康管理师 · 虚拟示例「韩老师」名片 + 三课程 + 两份知识文档
-- + 4 个 RPC 升级（example 字段 / fallback / 拒绝绑定）
-- ============================================================

-- 1) managers.is_example 列 + invite_code 放宽 NOT NULL（让示例可以 NULL）
ALTER TABLE managers
  ADD COLUMN IF NOT EXISTS is_example BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN managers.is_example IS '虚拟示例管理师标记：true 表示不可被真实绑定，是无活跃绑定用户的默认 fallback。';
ALTER TABLE managers ALTER COLUMN invite_code DROP NOT NULL;

-- 2) 种子 auth.users（仅在不存在时）
DO $seed_auth$
DECLARE
  v_uid CONSTANT UUID := '00000000-0000-0000-0000-00000000a001';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_uid) THEN
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change_token_new, email_change
    ) VALUES (
      '00000000-0000-0000-0000-000000000000', v_uid,
      'authenticated', 'authenticated',
      'example-han-laoshi@kaitong.local',
      crypt(gen_random_uuid()::text, gen_salt('bf')),
      NOW(),
      '{"provider": "system", "providers": ["system"], "is_example": true}'::jsonb,
      '{"nickname": "韩老师", "is_example": true}'::jsonb,
      NOW(), NOW(), '', '', '', ''
    );
  END IF;
END
$seed_auth$;

-- 3) 种子 profiles（UPSERT 兼容自动 trigger）
INSERT INTO profiles (
  id, phone, nickname, avatar_url, role, is_verified,
  real_name, id_card, is_disabled, sub_role, permissions,
  wechat_openid, wechat_nickname, wechat_avatar, wechat_unionid,
  phone_bindable, voice_preference, created_at, updated_at,
  disabled_reason
) VALUES (
  '00000000-0000-0000-0000-00000000a001',
  '', '韩老师',
  'https://b.ux-cdn.com/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png',
  'manager'::user_role, true,
  '', '', false, '', '{}'::jsonb,
  '', '', '', '',
  false, 'manager', NOW(), NOW(),
  ''
)
ON CONFLICT (id) DO UPDATE SET
  nickname = EXCLUDED.nickname,
  avatar_url = EXCLUDED.avatar_url,
  role = EXCLUDED.role,
  is_verified = EXCLUDED.is_verified,
  updated_at = NOW();

-- 4) 种子 managers
INSERT INTO managers (
  id, business_name, business_license, certification_status, membership_level,
  client_count, survey_count, created_at, updated_at,
  invite_code, intro_personal, intro_company, company_name,
  digital_avatar_image_url, digital_persona_video_url, tagline, credentials,
  partner_phone, partner_card_status, partner_card_public_url, partner_card_slug,
  partner_card_display_name, partner_card_avatar_url, partner_card_company_name,
  partner_card_error, featured_product_ids, is_example
) VALUES (
  '00000000-0000-0000-0000-00000000a001',
  '韩老师 · 养胃 IP', '', 'approved', 'free',
  0, 0, NOW(), NOW(),
  NULL,
  E'我叫韩老师，胃病康复亲历者。从 2010 年开始陪伴大家学习养胃，到现在已经 15 年。\n\n我并不是医生，而是一个曾经被胃病困扰整整十年的普通人——胃溃疡、萎缩性胃炎和肠易激综合征同时背在身上，体重一度只有 55 公斤。\n\n2009 年我开始系统学习营养学，把一日三餐的结构、温度、咀嚼习惯、情绪、作息全部重新拆开来重组，两年后体重稳定回到 70 公斤，胃镜复查也确认溃疡基本愈合。这 15 年间，已累计陪伴 5000 多位朋友穿越胃病低谷。',
  E'养胃 IP 是我个人的健康陪伴空间。\n\n我们不开药、不做诊断、不替代医生，只在「日常生活方式」这一层提供可复制、能坚持、能复盘的方案。每位朋友会拿到一份「4–12 周陪伴节奏表」，配套早餐、餐后、情绪、睡眠四个维度的小练习。\n\n所有内容定期复核，配合主管医生的意见使用，不取代任何处方。',
  '韩老师 · 养胃 IP',
  'https://b.ux-cdn.com/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png',
  '',
  '胃病康复亲历者 · 15 年 5000 成功案例缔造者',
  ARRAY['健康管理师', '公共营养师', '中国老年保健协会会员', '慢病康复产业委员会委员']::TEXT[],
  '', '', '', '',
  '韩老师',
  'https://b.ux-cdn.com/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png',
  '韩老师 · 养胃 IP',
  '', ARRAY[]::UUID[], TRUE
)
ON CONFLICT (id) DO UPDATE SET
  is_example = EXCLUDED.is_example,
  business_name = EXCLUDED.business_name,
  certification_status = EXCLUDED.certification_status,
  invite_code = EXCLUDED.invite_code,
  intro_personal = EXCLUDED.intro_personal,
  intro_company = EXCLUDED.intro_company,
  company_name = EXCLUDED.company_name,
  digital_avatar_image_url = EXCLUDED.digital_avatar_image_url,
  tagline = EXCLUDED.tagline,
  credentials = EXCLUDED.credentials,
  partner_card_display_name = EXCLUDED.partner_card_display_name,
  partner_card_avatar_url = EXCLUDED.partner_card_avatar_url,
  partner_card_company_name = EXCLUDED.partner_card_company_name,
  updated_at = NOW();

-- 5) 种子 3 门 manager_courses
INSERT INTO manager_courses (
  id, manager_id, title, cover_image_url, description, duration_minutes,
  chapters, is_published, sort_weight, created_at, updated_at
) VALUES
(
  '00000000-0000-0000-0000-00000000c001',
  '00000000-0000-0000-0000-00000000a001',
  '7 天养胃晨食方案',
  'https://b.ux-cdn.com/uxarts-agent/20260609/3a2430c792514f7b8ff66f00f773fba8.png',
  '配合季节与体质，给胃一份温柔的清晨——7 天替换你的早餐表，逐日记录身体反馈。',
  45,
  '[
    {"title": "为什么早晨决定一整天的胃", "intro": "晨起空腹的 30 分钟，是养胃黄金窗口。", "duration_minutes": 7},
    {"title": "小米山药粥的 3 种变化", "intro": "温补 / 补气 / 健脾，按当下体感选择。", "duration_minutes": 10},
    {"title": "咖啡 / 浓茶 / 冷饮的替代清单", "intro": "温热饮品如何不牺牲风味。", "duration_minutes": 12},
    {"title": "7 日早餐替换表", "intro": "逐日记录、对照打卡。", "duration_minutes": 16}
  ]'::jsonb,
  true, 100, NOW(), NOW()
),
(
  '00000000-0000-0000-0000-00000000c002',
  '00000000-0000-0000-0000-00000000a001',
  '胃部不适的 4 周调理日历',
  'https://b.ux-cdn.com/uxarts-agent/20260609/71e7b6e48923423f9f94a24f0dac0a17.png',
  '把模糊的「调理」落到每一天：饮食结构、温度选择、节奏、复盘，4 周走一遍。',
  60,
  '[
    {"title": "第 1 周 · 让胃先安静下来", "intro": "去掉刺激、降低进食速度，先建立稳定窗口。", "duration_minutes": 12},
    {"title": "第 2 周 · 加回常见食物的方法论", "intro": "如何安全地把豆制品 / 粗粮 / 水果加回到餐桌。", "duration_minutes": 16},
    {"title": "第 3 周 · 体感与情绪同步记录", "intro": "用一张表把腹胀、嗳气、心情记录起来。", "duration_minutes": 18},
    {"title": "第 4 周 · 复盘表与节奏延续", "intro": "把这一个月的变化稳定为长期习惯。", "duration_minutes": 14}
  ]'::jsonb,
  true, 90, NOW(), NOW()
),
(
  '00000000-0000-0000-0000-00000000c003',
  '00000000-0000-0000-0000-00000000a001',
  '慢病康复中的情绪与睡眠',
  'https://b.ux-cdn.com/uxarts-agent/20260609/89ec0bbadcf646e9ab3b11263b508aa0.png',
  '胃病和情绪、睡眠常常是一组三角关系——这门课讲解怎么从一个角拉回另一个角。',
  50,
  '[
    {"title": "胃肠 · 情绪 · 睡眠 三角模型", "intro": "为什么改一处会牵动另外两处。", "duration_minutes": 10},
    {"title": "4-7-8 呼吸与睡前 30 分钟练习", "intro": "睡前的可复制 10 分钟练习。", "duration_minutes": 12},
    {"title": "长期焦虑下的饮食侧调整", "intro": "焦虑高发期的「不和身体较劲」清单。", "duration_minutes": 14},
    {"title": "自我对话：不和身体较劲", "intro": "把康复理解为陪伴，而不是任务。", "duration_minutes": 14}
  ]'::jsonb,
  true, 80, NOW(), NOW()
)
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  cover_image_url = EXCLUDED.cover_image_url,
  description = EXCLUDED.description,
  duration_minutes = EXCLUDED.duration_minutes,
  chapters = EXCLUDED.chapters,
  is_published = EXCLUDED.is_published,
  sort_weight = EXCLUDED.sort_weight,
  updated_at = NOW();

-- 6) 种子 2 份 manager_knowledge_documents（status='ready' + content_text）
INSERT INTO manager_knowledge_documents (
  id, manager_id, title, storage_url, storage_key,
  file_size_bytes, mime_type, backend, external_file_id, external_index_id,
  status, error_message, content_text, created_at, updated_at
) VALUES
(
  '00000000-0000-0000-0000-00000000d001',
  '00000000-0000-0000-0000-00000000a001',
  '韩老师 · 我的康复故事与服务边界',
  '', '', 0, 'text/markdown', 'kqa', '', '',
  'ready', '',
  E'# 关于韩老师\n\n我叫韩老师，胃病康复亲历者，从 2010 年开始陪伴大家学习养胃，到现在已经 15 年。\n\n## 我的故事\n我并不是医生，而是一个曾经被胃病困扰整整十年的普通人。最严重的时候，我同时背着胃溃疡、萎缩性胃炎和肠易激综合征三张诊断书，体重一度只有 55 公斤，吃什么吐什么，白天上不了班，晚上睡不着觉。\n\n2009 年，我开始系统地学习营养学，从一日三餐的结构、温度、咀嚼习惯，到情绪、作息、运动节律，把每一个细节都重新拆开来重组。两年后，我的体重稳定回到 70 公斤，胃镜复查也确认溃疡基本愈合。从那以后，我陆续考下了健康管理师、公共营养师证书，加入了中国老年保健协会和慢病康复产业委员会，把这 15 年的实战经验整理成一套可复制的方案，目前已经累计陪伴超过 5000 位朋友穿越胃病低谷。\n\n## 我擅长什么\n* 萎缩性胃炎、慢性浅表性胃炎、胃溃疡的生活方式调理\n* 反酸、烧心、餐后腹胀、嗳气等常见胃部不适的非药物干预\n* 肠易激综合征的饮食与情绪双线调理\n* 二十岁以上、长期不规律饮食、压力大的都市人群体重与胃功能恢复\n\n## 我服务什么样的朋友\n* 二十岁以上，胃不舒服超过 3 个月，做过胃镜或 B 超\n* 愿意花 4–12 周时间慢慢调整，而不是追求三天见效\n* 接受「日常方案 + 阶段复盘」的陪伴节奏\n* 仍在医院规律就诊的朋友——我和医生的建议是叠加，不是替代\n\n## 我不会做这些事\n* 我不会诊断疾病、不会开药、不会做任何医学结论\n* 凡是涉及处方药、手术、放化疗的问题，请直接咨询主治医生\n* 如果出现剧烈疼痛、呕血、黑便、不明原因体重骤降、突然消瘦，请立即就医，不要在我这里等待\n\n## 价值观与表达风格\n我的回答会保持温和、克制、说人话，绝不堆术语；每一个建议都会标注「先做什么 / 持续多久 / 怎样判断有没有改善」。我相信慢病康复一定是日常一点点累积出来的，不是某一招神奇方法。\n\n## 非诊断声明\n我提供的是营养与生活方式建议，不能替代医院的诊断、治疗或处方。任何明确的疾病判断、用药调整、手术安排，请以你主治医生的意见为准。',
  NOW(), NOW()
),
(
  '00000000-0000-0000-0000-00000000d002',
  '00000000-0000-0000-0000-00000000a001',
  '韩老师 · 养胃常见问答与红旗症状',
  '', '', 0, 'text/markdown', 'kqa', '', '',
  'ready', '',
  E'# 常见问答与就医红旗\n\n下面是 5000 多位朋友在过去几年里最常问到的问题，以及我反复嘱咐的「红旗症状」清单——一旦命中，请立刻去医院，不要犹豫。\n\n## 一、晨起空腹该怎么吃\n推荐顺序：温水 200 毫升 → 小米 / 山药 / 南瓜 类温热主食 → 鸡蛋或豆制品。\n* 第一口务必是 40°C 左右的温水，把胃唤醒\n* 避开冷牛奶、冰豆浆、空腹苹果、空腹咖啡\n* 嗳气和反酸明显的朋友，前两周建议彻底避开浓茶\n\n## 二、餐后总觉得腹胀怎么办\n先从「吃饭快」入手：每口咀嚼 15 下以上，把进食时间拉到 20 分钟。\n辅助节奏：饭后 10 分钟靠墙站立、慢走 15 分钟，不要立刻躺下或弯腰。\n持续 2 周，若腹胀感未减轻 30%，建议复诊问医生是否需要做胃排空相关检查。\n\n## 三、可不可以一边吃药一边调理\n完全可以，而且强烈建议这么做。我提供的所有方法都是配合医嘱的「生活方式层」，不会、也不应该替代任何处方。\n如果你不确定某种食物会不会和你正在吃的药互相作用，请把药名告诉你的医生或药师，我不做任何药物层面的判断。\n\n## 四、肠易激和胃病的关系\n肠易激常常和长期焦虑、作息颠倒一起出现，需要「饮食 + 情绪」双线调理。\n常用建议：固定就寝时间（差异控制在 30 分钟内）、晚饭后 1 小时不再进食、睡前 10 分钟做 4-7-8 呼吸 3 轮、戒掉睡前刷手机。\n持续 4 周后若仍每周腹泻 3 次以上，请直接复查肠镜。\n\n## 五、什么样的体检 / 检查值得做\n* 半年内未做过胃镜的中年人，建议先做一次\n* 长期反酸、烧心 → 加做幽门螺旋杆菌 C13 / C14\n* 萎缩性胃炎复查周期：由消化内科医生决定，一般 1–2 年一次\n\n## 六、🚩 红旗症状（出现任意一条，立即就医，不在我这里等）\n1. 突发剧烈腹痛超过 1 小时不缓解\n2. 呕血或咖啡渣样呕吐物\n3. 解黑色柏油样大便，或大便带鲜红血\n4. 1 个月内非主动减重超过 5 公斤\n5. 持续吞咽困难、进食后哽噎\n6. 持续低热超过 2 周\n7. 夜间因痛醒、伴冷汗\n\n## 七、关于体重、情绪、生活方式的痛点\n很多朋友问我：「我每天都很累，没办法精心准备早餐怎么办？」\n这正是我设计「7 天养胃晨食方案」的初衷——把方案拆到分钟级，最忙的早晨也只需要 8 分钟。\n胃病调理不是「再来一份完美计划」，而是「在你的真实生活里找到容得下的小动作」。\n\n## 八、非诊断声明\n我提供的是营养与生活方式建议，不能替代医院的诊断、治疗或处方。任何明确的疾病判断、用药调整、手术安排，请以你主治医生的意见为准。我会陪你把日常的细节一点点做好，但医生才是你康复路上的主驾驶。',
  NOW(), NOW()
)
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  content_text = EXCLUDED.content_text,
  status = 'ready',
  updated_at = NOW();

-- ============================================================
-- 7) RPC: get_public_manager_card —— 增加 is_example
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_public_manager_card(p_manager_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_manager managers%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_courses JSON;
  v_featured_products JSON;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = p_manager_id;

  SELECT json_agg(
    json_build_object(
      'id', c.id,
      'title', c.title,
      'cover_image_url', c.cover_image_url,
      'description', c.description,
      'duration_minutes', c.duration_minutes,
      'chapter_count', COALESCE(jsonb_array_length(c.chapters), 0),
      'sort_weight', c.sort_weight
    )
    ORDER BY c.sort_weight DESC, c.created_at DESC
  ) INTO v_courses
  FROM manager_courses c
  WHERE c.manager_id = p_manager_id AND c.is_published = true;

  IF v_manager.featured_product_ids IS NOT NULL
     AND array_length(v_manager.featured_product_ids, 1) > 0 THEN
    SELECT json_agg(
      json_build_object(
        'id', p.id,
        'title', p.title,
        'cover_image_url', p.cover_image_url,
        'price_cents', sku.price_cents
      )
    ) INTO v_featured_products
    FROM products p
    LEFT JOIN product_skus sku
      ON sku.product_id = p.id
     AND sku.is_default = true
     AND sku.is_active = true
    WHERE p.id = ANY (v_manager.featured_product_ids)
      AND p.status = 'active';
  END IF;

  RETURN json_build_object(
    'manager_id', v_manager.id,
    'display_name', COALESCE(v_manager.partner_card_display_name, v_profile.nickname, '健康管理师'),
    'avatar_url', COALESCE(v_manager.digital_avatar_image_url, v_manager.partner_card_avatar_url, v_profile.avatar_url),
    'tagline', v_manager.tagline,
    'company_name', COALESCE(v_manager.company_name, v_manager.partner_card_company_name, v_manager.business_name),
    'intro_personal', v_manager.intro_personal,
    'intro_company', v_manager.intro_company,
    'credentials', v_manager.credentials,
    'digital_persona_video_url', v_manager.digital_persona_video_url,
    'partner_card_public_url', v_manager.partner_card_public_url,
    'partner_card_synced_at', v_manager.partner_card_synced_at,
    'is_example', COALESCE(v_manager.is_example, false),
    'featured_products', COALESCE(v_featured_products, '[]'::JSON),
    'courses', COALESCE(v_courses, '[]'::JSON)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_public_manager_card(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_manager_card(UUID) TO anon, authenticated;

-- ============================================================
-- 8) RPC: get_my_bound_manager_card —— fallback 韩老师 + source/is_bound
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_bound_manager_card()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_uid UUID;
  v_manager_id UUID;
  v_card JSON;
  v_doc_total INTEGER;
  v_doc_ready INTEGER;
  v_doc_failed INTEGER;
  v_doc_indexing INTEGER;
  v_is_bound BOOLEAN;
  v_source TEXT;
  v_example_uid CONSTANT UUID := '00000000-0000-0000-0000-00000000a001';
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT manager_id INTO v_manager_id
  FROM client_relations
  WHERE client_id = v_uid AND status = 'active'
  ORDER BY updated_at DESC NULLS LAST
  LIMIT 1;

  IF v_manager_id IS NULL THEN
    -- 无活跃绑定 → fallback 到示例韩老师
    v_manager_id := v_example_uid;
    v_is_bound := false;
    v_source := 'example';
  ELSE
    v_is_bound := true;
    v_source := 'bound';
  END IF;

  SELECT public.get_public_manager_card(v_manager_id) INTO v_card;
  IF v_card IS NULL THEN
    -- 兜底：找不到示例（理论上不会发生，但避免 null pointer）
    RETURN json_build_object(
      'card', NULL,
      'knowledge', json_build_object(
        'total_documents', 0,
        'ready_documents', 0,
        'failed_documents', 0,
        'indexing_documents', 0,
        'has_knowledge', false
      ),
      'source', v_source,
      'is_bound', v_is_bound
    );
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE TRUE),
    COUNT(*) FILTER (WHERE status = 'ready'),
    COUNT(*) FILTER (WHERE status = 'failed'),
    COUNT(*) FILTER (WHERE status IN ('uploading','indexing'))
  INTO v_doc_total, v_doc_ready, v_doc_failed, v_doc_indexing
  FROM manager_knowledge_documents
  WHERE manager_id = v_manager_id;

  RETURN json_build_object(
    'card', v_card,
    'knowledge', json_build_object(
      'total_documents', COALESCE(v_doc_total, 0),
      'ready_documents', COALESCE(v_doc_ready, 0),
      'failed_documents', COALESCE(v_doc_failed, 0),
      'indexing_documents', COALESCE(v_doc_indexing, 0),
      'has_knowledge', COALESCE(v_doc_ready, 0) > 0
    ),
    'source', v_source,
    'is_bound', v_is_bound
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_my_bound_manager_card() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_bound_manager_card() TO authenticated;

-- ============================================================
-- 9) RPC: bind_manager_from_card —— 拒绝 is_example=true
-- ============================================================
CREATE OR REPLACE FUNCTION public.bind_manager_from_card(
  p_manager_id UUID,
  p_invite_code TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_existing_id UUID;
  v_relation_id UUID;
  v_normalized TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  IF COALESCE(v_manager.is_example, false) THEN
    RAISE EXCEPTION '示例管理师不可绑定，请使用真实管理师的邀请码' USING ERRCODE = '22023';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);
  IF v_manager.invite_code IS NULL OR v_manager.invite_code <> v_normalized THEN
    RAISE EXCEPTION '邀请码错误' USING ERRCODE = '22023';
  END IF;

  SELECT manager_id INTO v_existing_id
  FROM client_relations
  WHERE client_id = v_uid AND status = 'active' AND manager_id <> p_manager_id
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    UPDATE client_relations
       SET status = 'inactive', updated_at = NOW()
     WHERE client_id = v_uid AND manager_id = v_existing_id;
  END IF;

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    INSERT INTO client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (p_manager_id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'manager_id', p_manager_id,
    'relation_id', v_relation_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_from_card(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_card(UUID, TEXT) TO authenticated;

-- ============================================================
-- 10) RPC: bind_manager_by_invite_code —— 排除 is_example=true
-- ============================================================
CREATE OR REPLACE FUNCTION public.bind_manager_by_invite_code(
  p_invite_code TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_existing_id UUID;
  v_relation_id UUID;
  v_normalized TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);

  SELECT * INTO v_manager
    FROM managers
   WHERE invite_code = v_normalized
     AND COALESCE(is_example, false) = false
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION '邀请码无效' USING ERRCODE = 'P0002';
  END IF;

  SELECT manager_id INTO v_existing_id
  FROM client_relations
  WHERE client_id = v_uid AND status = 'active' AND manager_id <> v_manager.id
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    UPDATE client_relations
       SET status = 'inactive', updated_at = NOW()
     WHERE client_id = v_uid AND manager_id = v_existing_id;
  END IF;

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = v_manager.id;

  IF v_relation_id IS NULL THEN
    INSERT INTO client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (v_manager.id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'manager_id', v_manager.id,
    'relation_id', v_relation_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_by_invite_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_by_invite_code(TEXT) TO authenticated;