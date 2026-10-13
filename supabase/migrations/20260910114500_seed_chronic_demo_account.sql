-- “安馨慢病健康管理中心”完整演示数据。
-- 全部绑定固定演示企业，虚拟客户均为禁用登录账号；企微与订单不触发真实外部动作。
ALTER TABLE public.client_relations DISABLE TRIGGER trg_enforce_membership_client_limit;
ALTER TABLE public.manager_content_items DISABLE TRIGGER manager_content_items_before_write_trg;

DO $demo$
DECLARE
  v_root CONSTANT uuid := 'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e';
  v_enterprise CONSTANT uuid := '72ae1cbc-ed74-4ffa-9a22-aa0ab23fe4f9';
  v_health_role uuid;
  v_staff_ids uuid[];
  v_client_ids uuid[] := ARRAY[]::uuid[];
  v_client uuid;
  v_record uuid;
  v_relation uuid;
  v_survey uuid;
  v_product uuid;
  v_category uuid;
  v_session uuid;
  v_weight numeric;
  v_bmi numeric;
  v_fat numeric;
  v_age integer;
  i integer := 0;
  j integer;
  c record;
  s record;
  q record;
  p record;
  f record;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.enterprises
    WHERE id = v_enterprise AND owner_profile_id = v_root
  ) THEN
    RAISE EXCEPTION '安馨慢病演示企业身份校验失败，已停止写入';
  END IF;

  SELECT id INTO v_health_role FROM public.enterprise_roles
  WHERE enterprise_id = v_enterprise AND code = 'health_manager';

  UPDATE public.profiles SET
    nickname = '何秀兰｜创始慢病管理师', role = 'manager', is_verified = true,
    privacy_settings = COALESCE(privacy_settings, '{}'::jsonb) || '{"show_phone":true,"share_vitals":true}'::jsonb,
    updated_at = now()
  WHERE id = v_root;

  UPDATE public.managers SET
    business_name = '慢病全程管理总顾问', company_name = '安馨慢病健康管理中心',
    certification_status = 'approved', is_example = true,
    tagline = '建档、监测、随访、复查，让慢病管理不断档',
    intro_personal = '演示人设：拥有护理与慢病随访背景，负责高血压、糖尿病、血脂异常和多病共管案例的团队统筹。',
    intro_company = '安馨慢病健康管理中心提供院外长期健康管理演示服务；所有人物与资历均为虚构，不替代医院诊断、处方和急救。',
    credentials = ARRAY['慢病健康管理方向（演示资料）','护理随访方向（演示资料）'],
    knowledge_system_prompt = '你是慢病全程管理总顾问。先核对诊断、近期指标、用药医嘱、症状、饮食运动和复查计划，再帮助用户记录、理解趋势并形成可执行的生活方式安排。不得诊断疾病、调整剂量、建议停药或承诺逆转；胸痛、呼吸困难、意识异常、严重低血糖或血压危象等情况应立即建议急诊。',
    public_qa_enabled = true,
    public_qa_welcome_message = '你好，我是何秀兰慢病管理顾问。请告诉我确诊情况、最近血压血糖或血脂指标、正在使用的药物及主要困扰。',
    updated_at = now()
  WHERE id = v_root;

  WITH team(system_key, nickname, phone, agent_name, tagline, intro, prompt) AS (
    VALUES
      ('chronic','徐慧敏｜糖尿病管理师','18800000411','血糖随访管理智能体','看懂血糖波动，把方案落实到每一餐','专注2型糖尿病、糖尿病前期的监测、依从性和复查提醒。','你是血糖随访助手。先询问确诊类型、用药、空腹及餐后血糖、糖化血红蛋白和低血糖史，再协助记录趋势与生活方式执行。不得调整药物；血糖严重异常、意识改变或反复低血糖应建议立即就医。'),
      ('gut','王志强｜心血管管理师','18800000412','血压心血管管理智能体','说话直接，先把风险和复查节点讲明白','专注高血压、冠心病术后和家庭血压监测。','你是血压与心血管随访助手。先确认测量姿势、近期血压、症状、诊断和药物医嘱，再解释趋势并给出测量、低盐与活动建议。不得调整药物；胸痛、呼吸困难、神经系统症状或血压危象应立即急诊。'),
      ('weight','李婉婷｜慢病营养顾问','18800000413','三高膳食管理智能体','家常饭也能兼顾血糖、血压和血脂','专注DASH饮食、控糖餐盘和三高家庭食谱。','你是三高膳食管理助手。结合疾病、用药、肾功能、饮食记录和家庭烹饪习惯提供份量与替换建议，不把食物描述成药物，不建议极端断食。肾病、孕期或明显指标异常需转专业人员。'),
      ('sleep','张淑芬｜血脂管理师','18800000414','血脂脂肪肝管理智能体','温和复盘，让长期改变真正坚持下来','专注血脂异常、脂肪肝与体重腰围趋势管理。','你是血脂与脂肪肝随访助手。先了解血脂化验、肝功能、饮酒、腰围、用药和医生计划，再协助制定饮食运动与复查提醒。不得承诺逆转或建议停药；异常肝功能应提示就医。'),
      ('fitness','刘一鸣｜随访数据专员','18800000415','复查提醒与数据智能体','指标有人记，复查有人提醒','负责复查计划、家庭监测汇总、异常提醒与家属同步。','你是慢病随访数据助手。帮助用户规范记录血压、血糖、体重、用药和复查日期，区分单次波动与持续趋势。只做管理支持，不诊断或改药；发现急性危险信号时立即提示急诊。')
  )
  UPDATE public.managers m SET
    business_name = t.nickname, company_name = '安馨慢病健康管理中心',
    certification_status = 'approved', is_system_default = false, is_example = true,
    tagline = t.tagline, intro_personal = t.intro,
    intro_company = '安馨慢病健康管理中心院外随访团队（全部为演示资料）。',
    credentials = ARRAY['慢病管理方向（演示资料）','健康随访方向（演示资料）'],
    knowledge_system_prompt = t.prompt, public_qa_enabled = true,
    public_qa_welcome_message = '你好，我是' || t.nickname || '。请先描述你的确诊情况、近期指标、用药医嘱和主要困扰。',
    updated_at = now()
  FROM team t
  WHERE m.enterprise_id = v_enterprise AND m.system_default_key = t.system_key;

  WITH team(system_key, nickname, phone) AS (
    VALUES
      ('chronic','徐慧敏｜糖尿病管理师','18800000411'),
      ('gut','王志强｜心血管管理师','18800000412'),
      ('weight','李婉婷｜慢病营养顾问','18800000413'),
      ('sleep','张淑芬｜血脂管理师','18800000414'),
      ('fitness','刘一鸣｜随访数据专员','18800000415')
  )
  UPDATE public.profiles pr SET
    nickname = t.nickname, phone = t.phone, role = 'manager', sub_role = 'health_manager',
    enterprise_role_id = v_health_role, is_verified = true, is_disabled = false,
    updated_at = now()
  FROM team t JOIN public.managers m ON m.system_default_key = t.system_key
  WHERE m.enterprise_id = v_enterprise AND pr.id = m.id;

  SELECT array_agg(m.id ORDER BY array_position(ARRAY['chronic','gut','weight','sleep','fitness'], m.system_default_key))
    INTO v_staff_ids
  FROM public.managers m
  WHERE m.enterprise_id = v_enterprise AND m.system_default_key IN ('chronic','gut','weight','sleep','fitness');

  WITH team(system_key, agent_name) AS (
    VALUES ('chronic','血糖随访管理智能体'),('gut','血压心血管管理智能体'),
           ('weight','三高膳食管理智能体'),('sleep','血脂脂肪肝管理智能体'),
           ('fitness','复查提醒与数据智能体')
  )
  UPDATE public.health_manager_agents a SET
    name = t.agent_name, status = 'published', is_active = true,
    config = COALESCE(a.config, '{}'::jsonb) || jsonb_build_object(
      'business_name', m.business_name, 'tagline', m.tagline,
      'intro_personal', m.intro_personal, 'intro_company', m.intro_company,
      'credentials', to_jsonb(m.credentials), 'knowledge_system_prompt', m.knowledge_system_prompt,
      'knowledge_model', m.knowledge_model, 'public_qa_enabled', true,
      'public_qa_welcome_message', m.public_qa_welcome_message
    ), updated_at = now()
  FROM team t JOIN public.managers m ON m.system_default_key = t.system_key AND m.enterprise_id = v_enterprise
  WHERE a.manager_id = m.id AND a.is_active;

  UPDATE public.health_manager_agents a SET
    name = '慢病全程管理总顾问', status = 'published', is_active = true,
    config = COALESCE(a.config, '{}'::jsonb) || jsonb_build_object(
      'business_name', m.business_name, 'tagline', m.tagline,
      'intro_personal', m.intro_personal, 'intro_company', m.intro_company,
      'credentials', to_jsonb(m.credentials), 'knowledge_system_prompt', m.knowledge_system_prompt,
      'knowledge_model', m.knowledge_model, 'public_qa_enabled', true,
      'public_qa_welcome_message', m.public_qa_welcome_message
    ), updated_at = now()
  FROM public.managers m WHERE a.manager_id = v_root AND m.id = v_root AND a.is_active;

  -- 24 位完全独立的虚拟客户；账号永久禁用，不能登录。
  FOR c IN SELECT * FROM (VALUES
    ('王桂芳','18810000401','female','1964-03-12'::date,158::numeric,63.0::numeric,-0.3::numeric,'2型糖尿病8年，近期糖化血红蛋白7.8%，重点提升用药与监测依从性。'),
    ('赵国栋','18810000402','male','1968-05-18',174,86.0,-0.4,'高血压合并脂肪肝，应酬较多，记录家庭血压并减少饮酒。'),
    ('孙秀兰','18810000403','female','1961-04-09',156,57.0,-0.1,'高血压15年，冠心病支架术后，按心内科医嘱进行渐进快走。'),
    ('陈志远','18810000404','male','1974-01-21',176,79.0,-0.3,'LDL-C偏高且睡眠不足，执行90天生活方式管理并按期复查。'),
    ('刘建华','18810000405','male','1965-06-11',170,82.0,-0.5,'糖尿病前期伴腹型肥胖，关注腰围、主食份量和餐后活动。'),
    ('周美玲','18810000406','female','1969-08-02',160,66.0,-0.2,'2型糖尿病3年，开店用餐不规律，复盘动态血糖与加餐时机。'),
    ('吴德顺','18810000407','male','1956-02-16',168,69.0,0.1,'高血压20年且多重用药，按医生和药师确认的时间表执行。'),
    ('郑彩霞','18810000408','female','1978-11-08',162,61.0,-0.2,'临界高血压伴更年期睡眠问题，执行DASH饮食和规律监测。'),
    ('罗建平','18810000409','male','1972-09-17',172,78.0,-0.3,'轻度脂肪肝与甘油三酯偏高，减少夜宵和含糖饮料。'),
    ('叶秋莲','18810000410','female','1959-05-22',155,58.0,0.1,'高血压控制基本稳定，强化规范测量与复诊记录。'),
    ('方明远','18810000411','male','1976-07-03',174,84.0,-0.4,'高血压合并超重，执行低盐餐盘并记录一周平均血压。'),
    ('梁慧琴','18810000412','female','1966-12-14',158,64.0,-0.2,'糖耐量异常，学习主食定量和饭后步行。'),
    ('郑建国','18810000413','male','1965-04-27',169,73.0,-0.2,'空腹血糖偏高，建立晨间血糖与早餐记录。'),
    ('韩书成','18810000414','male','1970-10-06',171,76.0,-0.2,'LDL-C偏高，按医生计划复查并改善膳食脂肪来源。'),
    ('江敏','18810000415','female','1963-01-19',158,67.0,-0.3,'围绝经期体重上升且血压临界，关注睡眠、腰围和力量活动。'),
    ('赵启航','18810000416','male','1958-06-25',175,75.0,0.1,'支架术后恢复期，依据康复医嘱逐步增加活动。'),
    ('吴佩芬','18810000417','female','1975-03-30',160,62.0,-0.2,'外卖频率高且血脂偏高，建立低盐低油点餐清单。'),
    ('何一帆','18810000418','male','1980-11-11',176,91.0,-0.5,'BMI偏高合并血压升高，控制夜间进食并记录腰围。'),
    ('苏梅','18810000419','female','1957-09-09',155,56.0,0.1,'高血压合并骨量关注，兼顾低盐与足量钙蛋白摄入。'),
    ('许文静','18810000420','female','1973-02-08',161,68.0,-0.3,'脂肪肝风险并久坐，安排餐后活动和每周体重趋势复盘。'),
    ('冯涛','18810000421','male','1960-08-15',173,80.0,-0.2,'尿酸和血压偏高，减少酒精、高盐聚餐并定期复查。'),
    ('秦悦华','18810000422','female','1968-05-04',160,59.0,-0.1,'糖尿病家族史，关注空腹血糖、睡眠和早餐结构。'),
    ('马俊杰','18810000423','male','1977-07-29',180,88.0,-0.4,'脂肪肝合并腹型肥胖，逐步增加有氧与抗阻活动。'),
    ('林澜','18810000424','female','1962-12-01',157,65.0,-0.2,'血压波动伴睡眠不足，先规范测量并排查高盐晚餐。')
  ) AS x(name, phone, gender, birth_date, height, weight, trend, notes)
  LOOP
    i := i + 1;
    v_client := gen_random_uuid();
    v_client_ids := array_append(v_client_ids, v_client);

    INSERT INTO auth.users (
      instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
      raw_app_meta_data,raw_user_meta_data,created_at,updated_at,
      confirmation_token,recovery_token,email_change_token_new,email_change,banned_until
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',v_client,'authenticated','authenticated',
      'demo-chronic-' || lpad(i::text,2,'0') || '@kaitong.local',
      extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),now(),
      '{"provider":"system","providers":["system"],"is_demo":true}'::jsonb,
      jsonb_build_object('nickname',c.name,'is_demo',true),now(),now(),'','','','',
      '9999-12-31 23:59:59+00'::timestamptz
    );

    INSERT INTO public.profiles (id,phone,nickname,role,privacy_settings,created_at,updated_at)
    VALUES (v_client,c.phone,c.name,'user','{"show_phone":true,"share_vitals":true}'::jsonb,now(),now())
    ON CONFLICT (id) DO UPDATE SET phone=EXCLUDED.phone,nickname=EXCLUDED.nickname,role='user',
      privacy_settings=EXCLUDED.privacy_settings,updated_at=now();

    INSERT INTO public.client_relations (
      manager_id,client_id,status,notes,last_contact_at,root_manager_id,customer_name,client_phone_normalized
    ) VALUES (
      v_staff_ids[((i-1)%5)+1],v_client,'active',c.notes,
      now() - ((i%8) || ' days')::interval,v_root,c.name,c.phone
    ) RETURNING id INTO v_relation;

    INSERT INTO public.follow_up_records (
      client_relation_id,content,follow_up_type,next_follow_up_at,reminder,created_by,created_at
    ) VALUES (
      v_relation,
      CASE i%4 WHEN 0 THEN '已复盘本周家庭监测记录，提醒继续按医嘱用药并准备复查数据。'
               WHEN 1 THEN '电话沟通执行情况，血压测量时间比上周更规律。'
               WHEN 2 THEN '已查看近期血糖与体重趋势，暂不自行调整药物。'
               ELSE '提醒完成本周指标、用药和症状记录，下次集中复盘。' END,
      CASE i%3 WHEN 0 THEN '电话' WHEN 1 THEN '企微' ELSE '复诊' END,
      now() + (((i%10)+1) || ' days')::interval,true,v_staff_ids[((i-1)%5)+1],
      now() - ((i%8) || ' days')::interval
    );

    INSERT INTO public.health_records (
      user_id,name,relationship,gender,birth_date,height,weight,is_default,medical_history,created_at,updated_at
    ) VALUES (
      v_client,c.name,'self',c.gender,c.birth_date,c.height,c.weight,true,c.notes,
      now() - interval '90 days',now()
    ) RETURNING id INTO v_record;

    INSERT INTO public.record_authorizations (record_id,manager_id,is_active,granted_at)
    VALUES (v_record,v_staff_ids[((i-1)%5)+1],true,now()-interval '90 days');

    v_age := date_part('year',age(c.birth_date));
    FOR j IN 1..3 LOOP
      v_weight := round((c.weight + (3-j)*c.trend)::numeric,1);
      v_bmi := round((v_weight / power(c.height/100,2))::numeric,1);
      v_fat := round(LEAST(42,GREATEST(10,(CASE WHEN c.gender='female' THEN 22 ELSE 17 END)+(v_bmi-22)*0.8))::numeric,1);
      INSERT INTO public.body_compositions (
        record_id,measured_at,provider_key,origin,weight,heart_rate,bmi,body_fat_percent,
        water_percent,skeletal_muscle_percent,muscle_mass,bone_mass,lbm,protein_percent,
        subcutaneous_fat_percent,visceral_fat_level,body_age,body_shape,bmr,health_score,
        metrics_meta,notes,oem_manager_id
      ) VALUES (
        v_record,now()-((3-j)*7 || ' days')::interval,'manual_demo','manual',v_weight,66+(i%13),v_bmi,v_fat,
        round((60-v_fat*0.25)::numeric,1),round((44-v_fat*0.18)::numeric,1),
        round((v_weight*(1-v_fat/100)*0.72)::numeric,1),round((v_weight*0.04)::numeric,1),
        round((v_weight*(1-v_fat/100))::numeric,1),round((18-v_fat*0.05)::numeric,1),
        round((v_fat*0.82)::numeric,1),round(LEAST(20,GREATEST(2,(v_bmi-17)*0.65))::numeric,1),
        GREATEST(18,v_age+(i%5)-2),CASE WHEN v_bmi<18.5 THEN '偏瘦' WHEN v_bmi<24 THEN '标准' WHEN v_bmi<28 THEN '偏重' ELSE '肥胖' END,
        round((10*v_weight+6.25*c.height-5*v_age+CASE WHEN c.gender='male' THEN 5 ELSE -161 END)::numeric),
        round(LEAST(95,GREATEST(58,90-abs(v_bmi-22)*2.2))::numeric,1),
        '{"demo":true,"source":"chronic_demo"}'::jsonb,'演示称重数据',v_staff_ids[((i-1)%5)+1]
      );
    END LOOP;
  END LOOP;

  -- 五套慢病问卷，共 40 题。
  FOR s IN SELECT * FROM jsonb_to_recordset($json$[
    {"title":"心脑血管风险初筛","description":"收集血压、血脂、家族史和生活方式信息，不用于诊断。","questions":["最近一周家庭血压范围？","是否确诊高血压或冠心病？","最近一次LDL-C是多少？","是否吸烟或饮酒？","是否出现胸痛、气促或头晕？","目前使用哪些药物？","每周中等强度活动几次？","计划何时复诊或复查？"]},
    {"title":"糖尿病自我管理行为评估","description":"了解监测、用药、饮食与运动执行情况。","questions":["最近空腹血糖范围？","餐后2小时血糖范围？","最近一次糖化血红蛋白？","是否按医嘱规律用药？","近一个月有无低血糖？","主食是否定量？","每周运动几天？","下次复查日期？"]},
    {"title":"家庭用药依从性评估","description":"帮助整理执行困难，不替代医生或药师核对。","questions":["当前每天需要服用几种药？","过去两周是否漏服？","是否会自行增减剂量？","是否清楚每种药的时间？","是否出现疑似不良反应？","家属是否协助提醒？","药盒或提醒工具是否有效？","最需要解决的用药困难？"]},
    {"title":"血脂与脂肪肝生活方式评估","description":"梳理饮食、饮酒、腰围和复查计划。","questions":["最近一次血脂结果？","肝功能是否异常？","当前腰围和体重？","每周饮酒频率？","夜宵和含糖饮料频率？","每周活动量？","是否已按医嘱用药？","计划何时复查？"]},
    {"title":"慢病会员服务满意度","description":"用于改进随访与提醒体验。","questions":["本月随访是否及时？","指标解释是否清楚？","提醒频率是否合适？","生活方式建议是否可执行？","家属同步是否有帮助？","最满意的服务环节？","最希望改进什么？","0到10分推荐意愿？"]}
  ]$json$::jsonb) AS z(title text,description text,questions jsonb)
  LOOP
    INSERT INTO public.surveys (manager_id,title,description,status,is_template,response_count)
    VALUES (v_root,s.title,s.description,'draft',false,3+(i%9)) RETURNING id INTO v_survey;
    INSERT INTO public.survey_questions (survey_id,question_type,title,options,is_required,display_order)
    SELECT v_survey,'text',value,NULL,true,ordinality-1
    FROM jsonb_array_elements_text(s.questions) WITH ORDINALITY;
    UPDATE public.surveys SET status='active',updated_at=now() WHERE id=v_survey;
  END LOOP;

  -- 六款慢病管理服务商品。
  FOR p IN SELECT * FROM (VALUES
    ('365慢病管理年卡（血压版）','血压建档、月度随访、复查提醒与家属同步',129900,47,'血压管理'),
    ('365慢病管理年卡（血糖版）','全年随访与12次血糖记录解读',159900,39,'血糖管理'),
    ('动态血糖14天监测服务','记录饮食活动并由管理师逐日复盘',39900,63,'血糖管理'),
    ('三高人群1对1膳食指导（月）','结合医嘱和家庭饮食制定可执行餐盘',29900,81,'慢病营养'),
    ('年度体检报告健康解读','逐项梳理指标并形成就医与生活行动清单',19900,56,'健康评估'),
    ('家庭血压管理服务包','规范测量教学、趋势周报与异常就医提醒',23900,34,'血压管理')
  ) AS x(title,subtitle,price,sales,category)
  LOOP
    INSERT INTO public.products (
      source_type,owner_manager_id,title,subtitle,description,cover_image_url,cover_images,gallery_images,
      category,tags,status,is_featured,sort_weight,sales_count,view_count,created_by,review_note
    ) VALUES (
      'manager',v_root,p.title,p.subtitle,p.subtitle || '。本商品为演示服务，不产生真实交易。','',
      '[]'::jsonb,'[]'::jsonb,p.category,ARRAY['慢病管理','演示服务'],'active',i<3,100-i,p.sales,500+p.sales*4,v_root,''
    ) RETURNING id INTO v_product;
    INSERT INTO public.product_skus (product_id,sku_code,price_cents,stock,attributes,is_default,is_active)
    VALUES (v_product,'DEMO-CHR-' || substr(replace(v_product::text,'-',''),1,8),p.price,999,'{"demo":true}'::jsonb,true,true);
  END LOOP;

  INSERT INTO public.manager_content_spaces (root_manager_id,display_name,reputation_name,created_by,updated_by)
  VALUES (v_root,'安馨慢病学堂','长期管理见证',v_root,v_root)
  ON CONFLICT (root_manager_id) DO UPDATE SET display_name=EXCLUDED.display_name,reputation_name=EXCLUDED.reputation_name,updated_at=now();

  FOR p IN SELECT * FROM (VALUES
    ('血压一到冬天就升高？先检查这5件事','天气变化时要加强家庭监测、保暖并保持规律服药。连续明显升高或伴胸痛、气促、神经症状时应及时就医，不能自行加药。'),
    ('糖友怎么吃饺子？先看份量和搭配','饺子并非绝对不能吃，可控制数量，搭配非淀粉类蔬菜，避免含糖蘸料，并根据个人血糖记录和医生建议调整。'),
    ('体检报告里值得长期跟踪的三个指标','血压、血糖和血脂要结合多次结果、既往病史与用药判断。一次异常不等于诊断，但持续异常应预约医生复查。'),
    ('降压药早上吃还是晚上吃？不要自行改时间','服药时间应遵循医生处方并结合药物种类和个人情况。管理师可以帮助记录，但不能代替医生调整剂量或时间。'),
    ('家庭测血糖，先把手洗净并擦干','残留食物可能影响指尖血糖结果。使用合格设备、按说明操作，并记录测量时间、进餐和用药信息，便于复盘。'),
    ('支架术后能不能运动？要按康复评估循序渐进','多数稳定期患者可在医生或心脏康复团队指导下活动，但出现胸痛、明显气促或眩晕应立即停止并就医。'),
    ('脂肪肝不只和体重有关','饮酒、代谢异常、药物等多种因素都可能相关。生活方式很重要，但确诊和复查仍需由医生结合影像与化验判断。'),
    ('老人总忘记吃药？试试一张清楚的用药表','把药名、剂量和时间按医生处方整理，使用分格药盒和家属提醒；任何调整都先询问医生或药师。'),
    ('糖尿病前期不是判决书，但也不能只靠感觉','通过体重管理、规律活动和合理饮食可降低进展风险，同时应按医生建议复查血糖和糖化血红蛋白。'),
    ('测血压的6个细节：坐稳、袖带合适、重复测量','测量前安静休息，背部和手臂有支撑，避免刚运动或饮咖啡后测量；用一周平均值和医生沟通更有意义。')
  ) AS x(title,body)
  LOOP
    INSERT INTO public.manager_content_items (
      root_manager_id,content_type,title,article_doc,is_published,sort_weight,moderation_status,
      moderation_labels,moderation_summary,moderated_at,created_by,updated_by,created_at,updated_at
    ) VALUES (
      v_root,'article',p.title,
      jsonb_build_object('type','doc','content',jsonb_build_array(jsonb_build_object('type','paragraph','content',jsonb_build_array(jsonb_build_object('type','text','text',p.body))))),
      true,100-i,'passed','[]'::jsonb,'演示内容已通过',now(),v_root,v_root,now()-(i||' days')::interval,now()
    );
  END LOOP;

  -- 标准问答库。
  INSERT INTO public.enterprise_qa_faqs (enterprise_id,question,answer,keywords,source,enabled,created_by)
  SELECT v_enterprise,x.question,x.answer,x.keywords,'manual',true,v_root FROM (VALUES
    ('家庭血压连续偏高怎么办？','先确认袖带、姿势和测量时间，连续记录并联系医生评估。若血压极高或伴胸痛、气促、肢体无力等症状，应立即急诊。',ARRAY['高血压','家庭监测']::text[]),
    ('降压药可以自己加半片吗？','不可以自行加减剂量。记录近期血压、症状和漏服情况，尽快联系开药医生决定是否调整。',ARRAY['高血压','用药']::text[]),
    ('血压正常了能停药吗？','不能仅凭几次正常值停药，正常可能正是药物和生活方式共同作用的结果，应由医生评估。',ARRAY['血压','停药']::text[]),
    ('空腹血糖7以上就是糖尿病吗？','单次家庭测量不能完成诊断，应到正规医疗机构按标准复查，并由医生结合症状和化验判断。',ARRAY['血糖','诊断']::text[]),
    ('糖友能吃水果吗？','多数人可以结合血糖、总量和时机适量吃完整水果，避免果汁；具体份量需个体化。',ARRAY['糖尿病','水果']::text[]),
    ('忘记吃药下一次要补双倍吗？','通常不应自行补双倍，但不同药物处理不同，请查看医嘱或尽快咨询医生、药师。',ARRAY['漏服','用药']::text[]),
    ('低血糖时应该怎么处理？','清醒且能吞咽时按既定低血糖方案补充快速碳水并复测；意识异常或无法吞咽应立即呼叫急救，不能强行喂食。',ARRAY['低血糖','急救']::text[]),
    ('测血压前要休息多久？','通常先安静坐位休息约5分钟，背部、手臂有支撑，双脚平放，袖带尺寸合适，再重复测量并记录。',ARRAY['血压','测量']::text[]),
    ('LDL高可以只靠饮食吗？','生活方式很重要，但是否需要药物取决于总体心血管风险和医生评估，不能因为改善饮食就自行拒绝或停用药物。',ARRAY['血脂','LDL']::text[]),
    ('脂肪肝是不是减肥就会好？','体重管理可能有帮助，但脂肪肝原因和程度不同，应结合肝功能、影像、饮酒和医生意见复查。',ARRAY['脂肪肝','体重']::text[]),
    ('支架术后可以快走吗？','稳定期常可在心脏康复或医生指导下循序渐进活动，但应以个人评估为准；胸痛或明显气促要立即停止并就医。',ARRAY['支架术后','运动']::text[]),
    ('DASH饮食最先改什么？','可先从减少盐和加工食品、增加蔬菜水果及适量奶豆开始，同时结合肾功能和医生要求。',ARRAY['DASH','低盐']::text[]),
    ('血糖每天波动很大怎么办？','把测量时间、进餐、活动、睡眠和用药一同记录，交给医生或管理团队判断；反复低血糖或明显高血糖应及时就医。',ARRAY['血糖','波动']::text[]),
    ('家用设备数据能代替医院检查吗？','不能。家庭设备适合趋势观察，异常值需要规范复测，诊断和治疗仍以医疗机构评估为准。',ARRAY['设备','复查']::text[]),
    ('慢病管理能保证不住院吗？','不能保证。管理服务用于提高监测和生活方式执行、提醒复查，不能消除疾病风险或替代医疗。',ARRAY['慢病管理','边界']::text[]),
    ('什么情况要立即急诊？','胸痛、严重呼吸困难、意识异常、单侧肢体无力、严重低血糖或血压危象伴症状等，应立即呼叫急救。',ARRAY['急诊','危险信号']::text[])
  ) AS x(question,answer,keywords);

  -- 六组自然咨询对话。
  FOR f IN SELECT * FROM (VALUES
    (v_staff_ids[1],'王桂芳','18810000401','荔枝到底能不能吃？','这两天想吃荔枝，空腹血糖大多在7左右。','可以先少量尝试完整水果，不喝果汁，放在两餐之间并记录前后血糖。具体份量仍要结合你的用药和医生要求，若血糖持续偏高要联系医生。'),
    (v_staff_ids[2],'赵国栋','18810000402','应酬后血压又高了','昨晚喝了酒，回家量到165/98，今天早上还有150多。','先安静休息后用规范姿势复测，记录症状和药物执行情况，不要自行加药。若出现胸痛、气促、视物异常或肢体无力，立即急诊；否则今天联系你的医生。'),
    (v_staff_ids[2],'孙秀兰','18810000403','支架术后快走可以加量吗？','现在每天走30分钟没胸闷，想加到45分钟。','恢复不错，但加量仍应遵循心脏康复或医生给你的范围。可以先小幅增加并观察心率、气促和胸部不适，任何警示症状都要立即停止。'),
    (v_staff_ids[4],'陈志远','18810000404','LDL降了一点还需要复查吗？','做了六周饮食运动，LDL从4.6到3.9。','变化值得肯定，但3.9是否达标取决于整体心血管风险。请按医生安排复查，不要仅凭下降就推迟评估；我们继续记录饮食、运动和睡眠。'),
    (v_staff_ids[3],'刘建华','18810000405','主食减得越少越好吗？','空腹血糖5.9了，我想把晚饭主食完全停掉。','不建议为了追求数字自行停掉主食。更稳妥的是控制份量、选择全谷杂豆并搭配蔬菜和蛋白质，再看餐后血糖与体重趋势。'),
    (v_staff_ids[5],'周美玲','18810000406','开店忙起来总忘吃饭','一忙就下午三点才吃，血糖忽高忽低。','先设两个固定提醒并准备可量化的小份加餐，把测量、进餐和用药时间一起记录。若反复低血糖或明显不适，要立即按医生方案处理并联系医疗人员。')
  ) AS x(manager_id,visitor_name,visitor_phone,title,user_msg,assistant_msg)
  LOOP
    INSERT INTO public.manager_public_qa_sessions (
      manager_id,visitor_token,visitor_phone,visitor_name,first_message,message_count,last_active_at,created_at
    ) VALUES (
      f.manager_id,'demo-chronic-'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
      f.visitor_phone,f.visitor_name,f.user_msg,4,now()-(i%5||' hours')::interval,now()-(i%9||' days')::interval
    ) RETURNING id INTO v_session;
    INSERT INTO public.manager_public_qa_messages (session_id,role,content,created_at) VALUES
      (v_session,'user',f.user_msg,now()-interval '12 minutes'),
      (v_session,'assistant',f.assistant_msg,now()-interval '11 minutes'),
      (v_session,'user','明白了，我先按这个方法记录三天。',now()-interval '4 minutes'),
      (v_session,'assistant','好的，记录时把时间、份量和身体感受一起写上，复盘会更准确。',now()-interval '3 minutes');
  END LOOP;

  INSERT INTO public.reputation_categories (root_manager_id,name,sort_weight)
  VALUES (v_root,'血糖管理',50),(v_root,'血压管理',40),(v_root,'心血管康复',30),(v_root,'血脂脂肪肝',20),(v_root,'家庭随访',10)
  ON CONFLICT (root_manager_id,name) DO NOTHING;

  FOR f IN SELECT * FROM (VALUES
    (1,'妈妈的血糖记录终于规律了','给妈妈用了血糖管理年卡后，每周报告都能看懂，漏服和复查也有人提醒。最重要的是遇到异常会明确叫我们联系医生。',5,860),
    (2,'应酬再多也开始认真量血压','以前只在头晕时量，现在能按周复盘，酒局后的异常也知道不能自己加药。王老师说话直接，但边界讲得很清楚。',5,720),
    (3,'支架术后敢慢慢走起来了','不是让我猛练，而是按医生康复范围一点点加量。现在能稳定快走，家里人也没那么紧张了。',5,645),
    (4,'生活方式有改善，复查也没耽误','LDL有下降，但团队没有夸大成“逆转”，一直提醒我按时找医生评估，这点让我放心。',4,590),
    (5,'减了几公斤，更重要是习惯稳了','主食不再乱砍，饭后活动和腰围记录都坚持下来了。空腹血糖比之前稳定，但我们仍按计划复查。',5,810)
  ) AS x(client_idx,title,content,rating,views)
  LOOP
    SELECT id INTO v_category FROM public.reputation_categories
    WHERE root_manager_id=v_root ORDER BY sort_weight DESC LIMIT 1 OFFSET ((f.client_idx-1)%5);
    INSERT INTO public.reputation_posts (
      root_manager_id,category_id,author_user_id,title,content,like_count,comment_count,
      moderation_status,review_note,base_view_count,is_pinned,pinned_rank,created_at,updated_at
    ) VALUES (
      v_root,v_category,v_client_ids[f.client_idx],f.title,f.content,18+f.client_idx*3,2+(f.client_idx%4),
      'passed','演示内容',f.views,f.rating=5,6-f.client_idx,now()-(f.client_idx*3||' days')::interval,now()
    );
  END LOOP;

  -- 企微助手仅展示，所有群关闭且无真实密钥。
  INSERT INTO public.merchant_wecom_settings (
    root_manager_id,scheduled_enabled,scheduled_time,timezone,agent_manager_id,welcome_message,
    single_chat_corp_id,single_chat_agent_id,single_chat_enabled
  ) VALUES (
    v_root,false,'09:00','Asia/Shanghai',v_root,
    '欢迎来到安馨慢病健康管理中心。请发送确诊情况、最近血压血糖或血脂指标、当前用药及下次复查日期，我们会安排对应管理师。','','',false
  ) ON CONFLICT (root_manager_id) DO NOTHING;

  INSERT INTO public.merchant_wecom_tips (root_manager_id,content,sort_order)
  SELECT v_root,x.content,x.ord FROM (VALUES
    (1,'家庭测血压前先安静坐5分钟，背部和手臂有支撑；关注一周平均值，不要只看单次波动。'),
    (2,'记录血糖时把进餐、活动、睡眠和用药时间一起写上，复盘才更有意义。'),
    (3,'血压或血糖变好也不要自行停药，任何剂量和时间调整都应由医生决定。'),
    (4,'低盐不只是少放盐，酱油、腌制品、加工肉和外卖酱汁同样需要留意。'),
    (5,'糖尿病管理不是完全不吃主食，而是结合个人情况控制份量、搭配结构并监测。'),
    (6,'LDL-C目标因心血管风险不同而不同，不能只拿一个通用数字判断是否达标。'),
    (7,'支架术后活动要按康复评估循序渐进，胸痛、明显气促或眩晕必须立即停止。'),
    (8,'家庭设备适合观察趋势，异常结果应规范复测，诊断和治疗仍以医疗机构评估为准。'),
    (9,'把药名、剂量、时间和用途整理成表格，交给医生或药师核对后再贴到固定位置。'),
    (10,'出现胸痛、意识异常、单侧无力、严重低血糖或血压危象伴症状，请立即呼叫急救。')
  ) AS x(ord,content)
  WHERE NOT EXISTS (SELECT 1 FROM public.merchant_wecom_tips t WHERE t.root_manager_id=v_root);

  INSERT INTO public.merchant_wecom_groups (root_manager_id,name,webhook_url,public_token,enabled,disabled_reason) VALUES
    (v_root,'演示｜血糖管理互助群','https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-chronic-0001','demo-chronic-group-0001',false,'演示数据，不执行真实推送'),
    (v_root,'演示｜家庭血压打卡群','https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-chronic-0002','demo-chronic-group-0002',false,'演示数据，不执行真实推送'),
    (v_root,'演示｜三高复查提醒群','https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-chronic-0003','demo-chronic-group-0003',false,'演示数据，不执行真实推送')
  ON CONFLICT (public_token) DO NOTHING;

  INSERT INTO public.merchant_wecom_contacts (
    root_manager_id,external_userid,type,name,follow_userids,source_state,last_message_at,first_seen_at
  )
  SELECT v_root,'demo_chronic_'||lpad(n::text,3,'0'),'contact',pr.nickname||'（演示）',ARRAY['demo_chronic_staff'],'demo',
         now()-(n||' hours')::interval,now()-(n*6||' days')::interval
  FROM generate_series(1,8) n JOIN public.profiles pr ON pr.id=v_client_ids[n]
  ON CONFLICT (root_manager_id,external_userid) DO NOTHING;
END
$demo$;

ALTER TABLE public.client_relations ENABLE TRIGGER trg_enforce_membership_client_limit;
ALTER TABLE public.manager_content_items ENABLE TRIGGER manager_content_items_before_write_trg;
