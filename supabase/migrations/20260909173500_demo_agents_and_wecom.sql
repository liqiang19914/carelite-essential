-- “疯狂椰子壳”演示企业：五个减重智能体 + 安全关闭的企微演示数据。
-- 所有记录都绑定固定演示企业/负责人；不写真实密钥，不开启任何外发能力。
DO $demo$
DECLARE
  v_root CONSTANT uuid := '9d20bc6b-cbd4-4153-84e5-01e5b58f041f';
  v_enterprise CONSTANT uuid := 'eb7e71d1-e2c1-4d75-87a8-d33f69b526fe';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.enterprises
    WHERE id = v_enterprise AND owner_profile_id = v_root
  ) THEN
    RAISE EXCEPTION '演示企业身份校验失败，已停止写入';
  END IF;

  WITH demo(manager_id, agent_name, tagline, intro_personal, credentials, system_prompt, welcome) AS (
    VALUES
      (v_root, '科学减重总顾问', '先评估，再定目标，让减重有据可循',
       '负责整合饮食、运动、睡眠与称重趋势，为客户制定可执行的阶段减重方案，并根据反馈动态调整。',
       ARRAY['科学减重方案设计','阶段目标管理','多维数据复盘']::text[],
       '你是科学减重总顾问。先了解身高、体重、腰围、作息、饮食、运动、疾病和用药，再给出分阶段建议。目标以可持续为先，通常建议每周下降0.25至1公斤；不用极端节食、泻药或未经证实的产品。回答要具体、温和、可执行，并提醒记录体重趋势。孕期、哺乳期、未成年人、进食障碍风险、明显不适或慢性病用药者，应建议咨询医生或营养专业人员，不作诊断。',
       '你好，我是科学减重总顾问。告诉我你的身高、体重、目标和最近一周的饮食作息，我先帮你做一次基础评估。'),
      ('97be8cc0-45cc-420f-ba8f-5df7a2b02f4f'::uuid, '饮食营养规划师', '不挨饿，也能把每一餐吃得更合理',
       '擅长从真实饮食习惯出发调整餐盘结构、蛋白质与膳食纤维摄入，提供容易坚持的外食和家庭餐方案。',
       ARRAY['膳食结构评估','减脂餐搭配','外食策略']::text[],
       '你是饮食营养规划师，围绕减脂期餐盘、蛋白质、蔬菜、主食、饮水和外食选择提供建议。优先在原有习惯上做小幅调整，给出份量和替换方案，不机械要求称重每一口食物，不鼓励断食或单一食物法。涉及过敏、妊娠、肾病、糖尿病或药物影响时，明确提示由医生或注册营养专业人员个体化评估。',
       '你好，我是饮食营养规划师。你可以把今天吃过的三餐和零食发给我，我会帮你找出最容易落地的调整点。'),
      ('aaf34d8b-4746-476c-aef1-9d27ac31975f'::uuid, '体重数据分析师', '看懂波动，比盯着单日数字更重要',
       '专注解读体重、BMI、体脂、腰围与基础代谢趋势，区分正常水分波动和真实变化，帮助客户稳定复盘。',
       ARRAY['体重趋势解读','BMI与体脂分析','称重习惯指导']::text[],
       '你是体重数据分析师。使用7日趋势而不是单日体重判断进展，结合身高、腰围、体脂、经期、盐分、睡眠和运动解释波动。计算时说明口径和局限，不把智能体脂秤数据当作医学诊断。发现体重短期异常变化、头晕乏力、水肿或其他警示症状时，建议及时就医。输出先给结论，再给两到三个可执行观察项。',
       '你好，我是体重数据分析师。发我最近7到14天的体重记录和身高，我来帮你判断真实趋势。'),
      ('1d6fe4ae-33e0-4a24-b41f-d8dbfe29ed2a'::uuid, '运动与塑形教练', '循序渐进，让运动真正融入生活',
       '根据体能基础、可用时间和关节情况安排有氧、力量与日常活动量，重点提升执行率并减少受伤风险。',
       ARRAY['减脂运动规划','居家力量训练','运动负荷调整']::text[],
       '你是运动与塑形教练。先询问运动基础、伤病、心血管风险、场地和时间，再给循序渐进的有氧与力量建议。使用主观用力程度和动作质量控制负荷，安排热身、休息与恢复，不承诺局部减脂。出现胸痛、呼吸困难、眩晕或急性疼痛时立即停止并建议就医。计划应简洁，能在用户现实日程中完成。',
       '你好，我是运动与塑形教练。告诉我每周能安排几次、每次多久，以及有没有膝腰不适，我帮你排一套可执行计划。'),
      ('3c5eca26-eb14-4318-897c-d4dcfc5b6e77'::uuid, '情绪进食与睡眠教练', '稳住情绪和睡眠，减重才更容易坚持',
       '帮助客户识别压力进食、夜间加餐与睡眠不足的触发点，用小步骤建立更稳定的行为节奏。',
       ARRAY['情绪进食识别','睡眠节律改善','习惯养成陪伴']::text[],
       '你是情绪进食与睡眠教练。用不评判的语言帮助用户识别饥饿、情绪、环境和睡眠触发因素，提供暂停练习、替代行为、环境调整和睡前流程。不要把意志力不足当作原因，也不进行心理疾病诊断。若出现催吐、暴食失控、自伤想法或持续严重失眠，应建议尽快联系医生或心理专业人员。每次只给少量可执行步骤。',
       '你好，我是情绪进食与睡眠教练。最近最容易失控进食是在什么时间、什么情境？我们从一个最小改变开始。')
  )
  UPDATE public.managers m
     SET business_name = d.agent_name,
         tagline = d.tagline,
         intro_personal = d.intro_personal,
         intro_company = '疯狂椰子壳科学减重团队，以饮食、运动、行为和数据复盘为核心，为不同阶段客户提供可持续的体重管理支持。',
         company_name = '疯狂椰子壳科学减重',
         credentials = d.credentials,
         knowledge_system_prompt = d.system_prompt,
         public_qa_enabled = true,
         public_qa_welcome_message = d.welcome,
         updated_at = now()
    FROM demo d
   WHERE m.id = d.manager_id
     AND public.get_profile_enterprise_id(m.id) = v_enterprise;

  WITH demo(manager_id, agent_name) AS (
    VALUES
      (v_root, '科学减重总顾问'),
      ('97be8cc0-45cc-420f-ba8f-5df7a2b02f4f'::uuid, '饮食营养规划师'),
      ('aaf34d8b-4746-476c-aef1-9d27ac31975f'::uuid, '体重数据分析师'),
      ('1d6fe4ae-33e0-4a24-b41f-d8dbfe29ed2a'::uuid, '运动与塑形教练'),
      ('3c5eca26-eb14-4318-897c-d4dcfc5b6e77'::uuid, '情绪进食与睡眠教练')
  )
  UPDATE public.health_manager_agents a
     SET name = d.agent_name,
         status = 'published',
         is_active = true,
         config = COALESCE(a.config, '{}'::jsonb) || jsonb_build_object(
           'business_name', m.business_name,
           'tagline', m.tagline,
           'intro_personal', m.intro_personal,
           'intro_company', m.intro_company,
           'credentials', to_jsonb(COALESCE(m.credentials, ARRAY[]::text[])),
           'knowledge_system_prompt', m.knowledge_system_prompt,
           'knowledge_model', m.knowledge_model,
           'public_qa_enabled', m.public_qa_enabled,
           'public_qa_welcome_message', m.public_qa_welcome_message
         ),
         updated_at = now()
    FROM demo d
    JOIN public.managers m ON m.id = d.manager_id
   WHERE a.manager_id = d.manager_id
     AND a.enterprise_id = v_enterprise
     AND a.is_active;

  INSERT INTO public.merchant_wecom_settings (
    root_manager_id, scheduled_enabled, scheduled_time, timezone,
    agent_manager_id, welcome_message, single_chat_corp_id, single_chat_agent_id,
    single_chat_enabled
  ) VALUES (
    v_root, false, '09:00', 'Asia/Shanghai', v_root,
    '欢迎加入疯狂椰子壳科学减重计划。请先发送身高、当前体重、目标体重和日常作息，健康管理师会结合你的情况给出建议。',
    '', '', false
  ) ON CONFLICT (root_manager_id) DO NOTHING;

  INSERT INTO public.merchant_wecom_tips (root_manager_id, content, sort_order)
  SELECT v_root, t.content, t.sort_order
  FROM (VALUES
    (1, '称重尽量固定在晨起、排空后、进食前进行；关注7天平均趋势，不必为单日波动焦虑。'),
    (2, '每餐先保证一掌心左右的优质蛋白，再搭配足量蔬菜和适量主食，更利于稳定饱腹感。'),
    (3, '外食时优先选择清蒸、炖煮或少油快炒，酱汁分开放，通常比完全不吃主食更容易长期坚持。'),
    (4, '减脂期也需要恢复。连续睡眠不足会影响食欲和训练状态，今晚可以先尝试比平时早睡20分钟。'),
    (5, '没有完整一小时也没关系：餐后快走10到15分钟，累积起来同样是有效的日常活动。'),
    (6, '体重停滞一两周很常见，先检查盐分、经期、排便、睡眠和记录完整度，再决定是否调整计划。'),
    (7, '真正的饥饿通常逐渐出现；如果突然特别想吃某一种食物，可以先停一分钟，看看是不是压力或疲劳。'),
    (8, '力量训练期间体重不一定快速下降，同时记录腰围、衣服松紧和训练表现会更全面。'),
    (9, '一顿吃多不会毁掉计划。下一餐恢复正常结构即可，不需要用断食或过量运动来补偿。'),
    (10, '合理减重通常以每周约0.25至1公斤为宜；如果持续乏力、头晕或心悸，请停止激进控制并及时咨询医生。')
  ) AS t(sort_order, content)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.merchant_wecom_tips x WHERE x.root_manager_id = v_root
  );

  INSERT INTO public.merchant_wecom_groups (
    root_manager_id, name, webhook_url, public_token, enabled, disabled_reason
  ) VALUES
    (v_root, '演示｜21天轻体打卡群', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-weight-loss-0001', 'demo-wecom-group-0001', false, '演示数据，不执行真实推送'),
    (v_root, '演示｜饮食复盘交流群', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-weight-loss-0002', 'demo-wecom-group-0002', false, '演示数据，不执行真实推送'),
    (v_root, '演示｜运动习惯养成群', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-weight-loss-0003', 'demo-wecom-group-0003', false, '演示数据，不执行真实推送')
  ON CONFLICT (public_token) DO UPDATE
    SET name = EXCLUDED.name,
        enabled = false,
        disabled_reason = EXCLUDED.disabled_reason,
        updated_at = now();

  INSERT INTO public.merchant_wecom_contacts (
    root_manager_id, external_userid, type, name, follow_userids,
    source_state, last_message_at, first_seen_at
  ) VALUES
    (v_root, 'demo_weight_001', 'contact', '林晓晴（演示）', ARRAY['demo_coach_nutrition'], 'demo', now() - interval '35 minutes', now() - interval '46 days'),
    (v_root, 'demo_weight_002', 'contact', '周子涵（演示）', ARRAY['demo_coach_data'], 'demo', now() - interval '3 hours', now() - interval '31 days'),
    (v_root, 'demo_weight_003', 'contact', '陈嘉宁（演示）', ARRAY['demo_coach_sport'], 'demo', now() - interval '1 day', now() - interval '27 days'),
    (v_root, 'demo_weight_004', 'contact', '王敏（演示）', ARRAY['demo_coach_behavior'], 'demo', now() - interval '2 days', now() - interval '19 days'),
    (v_root, 'demo_weight_005', 'contact', '许文博（演示）', ARRAY['demo_coach_data'], 'demo', now() - interval '4 days', now() - interval '14 days'),
    (v_root, 'demo_weight_006', 'contact', '唐悦（演示）', ARRAY['demo_coach_nutrition'], 'demo', now() - interval '6 days', now() - interval '9 days')
  ON CONFLICT (root_manager_id, external_userid) DO UPDATE
    SET name = EXCLUDED.name,
        follow_userids = EXCLUDED.follow_userids,
        source_state = 'demo',
        last_message_at = EXCLUDED.last_message_at,
        updated_at = now();
END
$demo$;
