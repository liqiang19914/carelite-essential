-- “膳衡营养健康中心”完整演示数据。
-- 全部绑定固定演示企业，虚拟客户均为禁用登录账号；企微与订单不触发真实外部动作。
ALTER TABLE public.client_relations DISABLE TRIGGER trg_enforce_membership_client_limit;
ALTER TABLE public.manager_content_items DISABLE TRIGGER manager_content_items_before_write_trg;

DO $demo$
DECLARE
  v_root CONSTANT uuid := 'c6cc187c-3b13-40fc-befb-aa70594ebe3c';
  v_enterprise CONSTANT uuid := 'a97f266d-383a-4cc4-ab1c-5d8b91264a54';
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
    RAISE EXCEPTION '膳衡演示企业身份校验失败，已停止写入';
  END IF;

  SELECT id INTO v_health_role FROM public.enterprise_roles
  WHERE enterprise_id = v_enterprise AND code = 'health_manager';

  UPDATE public.profiles SET
    nickname = '许雯静｜创始营养师', role = 'manager', is_verified = true,
    privacy_settings = COALESCE(privacy_settings, '{}'::jsonb) || '{"show_phone":true,"share_vitals":true}'::jsonb,
    updated_at = now()
  WHERE id = v_root;

  UPDATE public.managers SET
    business_name = '全人群营养总顾问', company_name = '膳衡营养健康中心',
    certification_status = 'approved', is_example = true,
    tagline = '把复杂营养问题，变成每天吃得明白',
    intro_personal = '演示人设：负责全人群营养评估与复杂案例统筹，覆盖孕产、儿童、慢病、术后和运动营养。',
    intro_company = '膳衡营养健康中心提供循证膳食评估和长期营养管理；演示数据不构成诊断或个体化医疗建议。',
    credentials = ARRAY['注册营养师方向（演示资料）','临床营养支持方向（演示资料）'],
    knowledge_system_prompt = '你是全人群营养总顾问。先了解年龄、身高体重、饮食、疾病、用药、过敏和检查结果，再给出循证、可执行的膳食建议。不夸大食物疗效，不替代诊断和处方；涉及孕产、儿童、肾病、肿瘤、术后、进食障碍或明显异常指标时，提醒由医生或注册营养师面诊。回答要说明适用条件、份量和复查节点。',
    public_qa_enabled = true,
    public_qa_welcome_message = '你好，我是许雯静营养顾问。请告诉我年龄、主要营养困扰、疾病或用药情况，以及最近一天吃了什么。',
    updated_at = now()
  WHERE id = v_root;

  WITH team(system_key, nickname, phone, agent_name, tagline, intro, prompt) AS (
    VALUES
      ('chronic','陆晓峰｜慢病营养师','18800000311','慢病膳食管理智能体','看得懂指标，也做得到三餐调整','专注痛风、糖尿病、高血压及肾病等慢病膳食管理。','你是慢病膳食管理助手。必须先问疾病诊断、化验结果、用药和医生要求，再讨论食物份量、烹调和外食选择。不得建议停药或用食物替代治疗；尿酸、血糖、肾功能明显异常时提示就医复查。'),
      ('gut','唐雅琴｜孕产营养师','18800000312','孕产营养管理智能体','从备孕到哺乳，让每一口更安心','专注孕期体重、血糖、贫血及哺乳期膳食支持。','你是孕产营养管理助手。结合孕周、孕前BMI、体重增长、糖耐量、血红蛋白和产检要求提供建议。避免生食、酒精和高风险补充剂；异常血糖、持续呕吐或其他警示情况应建议联系产科医生。'),
      ('weight','白若琳｜儿童营养师','18800000313','儿童成长营养智能体','不追喂、不强迫，陪孩子把饭吃好','专注儿童挑食、偏食、生长缓慢与家庭喂养行为。','你是儿童成长营养助手。先问年龄、身高体重百分位、进食行为、过敏和儿科评估，再给家庭餐与行为建议。儿童不套用成人BMI减重标准，不鼓励限制性节食；生长曲线下降、吞咽困难或疑似营养不良应建议儿科就诊。'),
      ('sleep','宋志强｜运动营养师','18800000314','运动营养与增肌智能体','吃训协同，提升表现而非盲目堆蛋白','专注增肌、耐力运动、赛前赛后补给和体成分优化。','你是运动营养助手。根据体重、训练类型、时长、目标和胃肠耐受安排能量、蛋白质、碳水与补水。避免无依据的大剂量补剂和兴奋剂建议；有基础疾病或竞技反兴奋剂要求时提醒咨询专业人员。'),
      ('fitness','陈佳宁｜体重管理营养师','18800000315','体重管理膳食智能体','不极端节食，用稳定结构换长期结果','专注减脂期膳食结构、外食策略与体重趋势复盘。','你是体重管理营养助手。结合身高体重、腰围、饮食、睡眠和活动量给出温和能量缺口与餐盘建议，通常以每周0.25至1公斤为可持续范围。不推荐极端节食、泻药或代餐替代全部正餐；异常症状及时转诊。')
  )
  UPDATE public.managers m SET
    business_name = t.nickname, company_name = '膳衡营养健康中心',
    certification_status = 'approved', is_system_default = false, is_example = true,
    tagline = t.tagline, intro_personal = t.intro,
    intro_company = '膳衡营养健康中心循证营养管理团队（全部为演示资料）。',
    credentials = ARRAY['营养管理方向（演示资料）','专项膳食指导（演示资料）'],
    knowledge_system_prompt = t.prompt, public_qa_enabled = true,
    public_qa_welcome_message = '你好，我是' || t.nickname || '。请先简单描述你的营养目标和目前情况。',
    updated_at = now()
  FROM team t
  WHERE m.enterprise_id = v_enterprise AND m.system_default_key = t.system_key;

  WITH team(system_key, nickname, phone) AS (
    VALUES
      ('chronic','陆晓峰｜慢病营养师','18800000311'),
      ('gut','唐雅琴｜孕产营养师','18800000312'),
      ('weight','白若琳｜儿童营养师','18800000313'),
      ('sleep','宋志强｜运动营养师','18800000314'),
      ('fitness','陈佳宁｜体重管理营养师','18800000315')
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
    VALUES ('chronic','慢病膳食管理智能体'),('gut','孕产营养管理智能体'),
           ('weight','儿童成长营养智能体'),('sleep','运动营养与增肌智能体'),
           ('fitness','体重管理膳食智能体')
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
    name = '全人群营养总顾问', status = 'published', is_active = true,
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
    ('顾蔓','18810000301','female','1996-03-12'::date,162::numeric,61.0::numeric,-0.2::numeric,'孕24周，关注妊娠期血糖和加餐安排。'),
    ('姜文博','18810000302','male','1999-05-18',178,72.0,-0.4,'增肌期胃肠胀气，需调整蛋白来源与分餐。'),
    ('谢安琪','18810000303','female','2017-04-09',132,27.0,-0.2,'儿童挑食偏瘦，执行食物冒险家计划。'),
    ('彭秀珍','18810000304','female','1958-01-21',156,49.0,-0.3,'术后营养恢复，少量多餐并复查白蛋白。'),
    ('石俊豪','18810000305','male','2014-06-11',156,68.0,0.5,'儿童体重偏高，采用家校联合膳食方案。'),
    ('涂雅静','18810000306','female','1991-08-02',165,57.0,0.1,'肠易激饮食观察，处于食物再引入阶段。'),
    ('丁一鸣','18810000307','male','1981-02-16',175,82.0,0.5,'痛风恢复期，重点管理酒精、浓汤和应酬。'),
    ('孟祥雪','18810000308','female','2000-11-08',164,51.0,-0.3,'纯素饮食，关注铁和维生素B12摄入。'),
    ('罗晨','18810000309','male','1988-09-17',172,78.0,0.4,'脂肪肝风险，开始减少含糖饮料和夜宵。'),
    ('叶思雨','18810000310','female','1994-05-22',160,46.0,-0.2,'体重偏低，提升全天能量与蛋白密度。'),
    ('方明远','18810000311','male','1976-07-03',174,84.0,0.4,'高血压合并超重，执行低盐餐盘。'),
    ('梁可欣','18810000312','female','1998-12-14',168,63.0,0.2,'办公室久坐，规律早餐并增加日常活动。'),
    ('郑建国','18810000313','male','1965-04-27',169,70.0,0.1,'血糖偏高，学习主食定量和餐后活动。'),
    ('韩书瑶','18810000314','female','1990-10-06',163,59.0,0.2,'备孕期营养评估，调整叶酸和饮食结构。'),
    ('江敏','18810000315','female','1983-01-19',158,67.0,0.3,'围绝经期体重上升，关注蛋白和力量训练。'),
    ('赵启航','18810000316','male','2002-06-25',181,76.0,-0.3,'耐力跑训练，改善赛前碳水与补水。'),
    ('吴佩琪','18810000317','female','1995-03-30',166,54.0,0.1,'反复外卖，建立一周家庭备餐模板。'),
    ('何一帆','18810000318','male','1986-11-11',176,91.0,0.6,'BMI偏高，控制夜间进食并记录腰围。'),
    ('苏梅','18810000319','female','1971-09-09',155,52.0,0.1,'骨量关注，增加奶豆制品与抗阻活动。'),
    ('许婧','18810000320','female','1993-02-08',161,58.0,0.2,'轻度缺铁风险，优化含铁食物搭配。'),
    ('冯涛','18810000321','male','1980-08-15',173,80.0,0.4,'尿酸偏高，减少酒精和高嘌呤聚餐。'),
    ('秦悦','18810000322','female','2004-05-04',170,49.0,-0.3,'素食且运动量大，提升能量与蛋白摄入。'),
    ('马俊杰','18810000323','male','1997-07-29',180,86.0,0.3,'增肌减脂并行，调整训练日碳水分配。'),
    ('林澜','18810000324','female','1989-12-01',164,64.0,0.2,'睡眠不足伴零食增多，先稳定作息和三餐。')
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
      'demo-nutrition-' || lpad(i::text,2,'0') || '@kaitong.local',
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
      CASE i%4 WHEN 0 THEN '已复盘三日饮食记录，建议先稳定早餐蛋白质。'
               WHEN 1 THEN '电话沟通执行情况，外食选择比上周更稳定。'
               WHEN 2 THEN '已查看最新体重趋势，暂不调整总能量。'
               ELSE '提醒完成本周食物与症状记录，下次集中复盘。' END,
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
        '{"demo":true,"source":"nutrition_demo"}'::jsonb,'演示称重数据',v_staff_ids[((i-1)%5)+1]
      );
    END LOOP;
  END LOOP;

  -- 五套营养问卷，共 40 题。
  FOR s IN SELECT * FROM jsonb_to_recordset($json$[
    {"title":"24小时膳食回顾与结构评估","description":"回顾昨日进食、饮水与用餐节律。","questions":["昨天吃了几餐？","早餐通常包含哪些食物？","每餐蔬菜大约多少？","每天奶类或替代品摄入多少？","昨天是否饮用含糖饮料？","外卖或在外就餐频率？","全天饮水量约多少？","最希望改善哪一餐？"]},
    {"title":"孕期营养风险筛查","description":"用于孕期营养管理前的信息收集，不替代产检。","questions":["目前孕周是多少？","孕前身高和体重是多少？","近四周体重变化如何？","是否完成糖耐量检查？","是否有贫血或铁蛋白偏低？","每天是否摄入奶、蛋、肉或豆制品？","是否存在恶心呕吐或进食困难？","目前使用哪些营养补充剂？"]},
    {"title":"儿童饮食行为问卷（家长版）","description":"了解儿童生长、挑食和家庭喂养环境。","questions":["孩子年龄及最近身高体重？","通常一餐需要多长时间？","会主动尝试新食物吗？","拒绝哪些食物类别？","家长是否追喂或用零食奖励？","每天零食和含糖饮料频率？","是否存在食物过敏？","近半年生长曲线是否下降？"]},
    {"title":"痛风生活方式与膳食评估","description":"了解尿酸、饮酒、饮水和高嘌呤食物暴露。","questions":["最近一次尿酸值是多少？","近一年急性发作几次？","目前是否规律用药？","每周饮酒几次？","浓肉汤或内脏摄入频率？","每天饮水大约多少？","是否合并高血压或肾功能异常？","最难改变的应酬场景是什么？"]},
    {"title":"运动与体重管理营养评估","description":"匹配训练、体成分和恢复需求。","questions":["当前目标是减脂、增肌还是表现提升？","每周训练次数和类型？","训练前通常吃什么？","训练后多久进餐？","每日蛋白质主要来源？","是否使用运动补充剂？","睡眠时长和恢复感受？","最近三个月体重和围度变化？"]}
  ]$json$::jsonb) AS z(title text,description text,questions jsonb)
  LOOP
    INSERT INTO public.surveys (manager_id,title,description,status,is_template,response_count)
    VALUES (v_root,s.title,s.description,'draft',false,3+(i%9)) RETURNING id INTO v_survey;
    INSERT INTO public.survey_questions (survey_id,question_type,title,options,is_required,display_order)
    SELECT v_survey,'text',value,NULL,true,ordinality-1
    FROM jsonb_array_elements_text(s.questions) WITH ORDINALITY;
    UPDATE public.surveys SET status='active',updated_at=now() WHERE id=v_survey;
  END LOOP;

  -- 六款营养服务商品。
  FOR p IN SELECT * FROM (VALUES
    ('孕期营养全程管理','从建档到产后，含阶段评估与随访',298000,34,'孕产营养'),
    ('儿童成长营养评估＋90天跟进','生长曲线、饮食行为和家庭方案',128000,41,'儿童营养'),
    ('1对1膳食方案（月度）','慢病、减脂或增肌个体化膳食复盘',39900,178,'营养咨询'),
    ('痛风饮食管理月卡','嘌呤红绿灯、应酬策略与每周复盘',49900,36,'慢病营养'),
    ('术后营养支持评估','出院后进食与口服营养支持方案',59900,29,'临床营养'),
    ('低FODMAP分阶段指导包','严格期、再引入期及个体化维持指导',69900,22,'胃肠营养')
  ) AS x(title,subtitle,price,sales,category)
  LOOP
    INSERT INTO public.products (
      source_type,owner_manager_id,title,subtitle,description,cover_image_url,cover_images,gallery_images,
      category,tags,status,is_featured,sort_weight,sales_count,view_count,created_by,review_note
    ) VALUES (
      'manager',v_root,p.title,p.subtitle,p.subtitle || '。本商品为演示服务，不产生真实交易。','',
      '[]'::jsonb,'[]'::jsonb,p.category,ARRAY['营养管理','演示服务'],'active',i<3,100-i,p.sales,500+p.sales*4,v_root,''
    ) RETURNING id INTO v_product;
    INSERT INTO public.product_skus (product_id,sku_code,price_cents,stock,attributes,is_default,is_active)
    VALUES (v_product,'DEMO-NUT-' || substr(replace(v_product::text,'-',''),1,8),p.price,999,'{"demo":true}'::jsonb,true,true);
  END LOOP;

  INSERT INTO public.manager_content_spaces (root_manager_id,display_name,reputation_name,created_by,updated_by)
  VALUES (v_root,'膳衡营养课堂','真实改变故事',v_root,v_root)
  ON CONFLICT (root_manager_id) DO UPDATE SET display_name=EXCLUDED.display_name,reputation_name=EXCLUDED.reputation_name,updated_at=now();

  FOR p IN SELECT * FROM (VALUES
    ('孕期血糖高？先别慌，这样安排三餐和加餐','孕期控糖不是不吃主食，而是把主食定量、分配到三餐，并搭配蛋白质和蔬菜。糖耐量异常应按产科要求监测和复诊。'),
    ('孩子挑食别硬喂：试试“食物冒险家”方法','从触摸、闻味、舔尝到吃一小口，允许孩子分阶段熟悉新食物。家长负责提供，孩子决定吃多少。'),
    ('痛风的人到底能不能吃豆腐？','豆制品通常不是痛风管理的首要矛盾。更应关注动物内脏、浓肉汤、酒精、含糖饮料和总体饮食结构，并结合医生用药。'),
    ('术后出院怎么补？别急着喝浓汤','术后恢复更需要足量能量和优质蛋白。少量多餐、软烂易消化，并按医嘱选择口服营养补充。'),
    ('纯素饮食如何把铁和B12吃明白','植物铁可与维生素C丰富食物同餐，提高吸收；维生素B12往往需要强化食品或专业评估后的补充。'),
    ('增肌期狂吃鸡胸肉，为什么反而不舒服？','增肌不仅看蛋白总量，也要看全天能量、碳水、脂肪和胃肠耐受。把蛋白分配到多餐通常更友好。'),
    ('低FODMAP饮食不是长期禁食清单','低FODMAP通常分严格限制、逐项再引入和个体化维持三个阶段，长期过度限制可能影响膳食多样性。'),
    ('儿童体重管理，最先改变的是家庭环境','儿童不应照搬成人减肥法。减少高能量零食暴露、规律家庭餐、保证睡眠和活动，比盯着体重数字更重要。')
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
    ('孕晚期能吃螃蟹吗？','一般可以少量食用，但必须新鲜、彻底熟透并去除内脏；有海鲜过敏或医生特别限制时应避免。',ARRAY['孕期','螃蟹']::text[]),
    ('孩子不爱吃青菜怎么办？','先减少强迫，尝试切丝混入肉馅、改变烹调方式，并让孩子反复少量接触。关注一周整体摄入，不用一餐定成败。',ARRAY['儿童','挑食','蔬菜']::text[]),
    ('痛风可以吃豆腐吗？','多数人可以适量吃豆腐。痛风管理更需限制酒精、动物内脏和浓肉汤，并结合尿酸、肾功能和医生用药。',ARRAY['痛风','豆腐','尿酸']::text[]),
    ('尿酸高是不是完全不能吃海鲜？','不必一刀切。急性期和稳定期策略不同，应区分种类和份量；贝类、部分小鱼干等需更谨慎，同时避免饮酒。',ARRAY['尿酸','海鲜']::text[]),
    ('减脂每天要吃多少蛋白质？','需结合体重、运动量、肾功能和总能量评估。一般应分配到三餐，优先鱼禽蛋奶豆等多样来源。',ARRAY['减脂','蛋白质']::text[]),
    ('增肌必须喝蛋白粉吗？','不是必须。食物能满足总能量和蛋白需要时无需额外补充；蛋白粉只是便利食品，应考虑胃肠耐受和总体饮食。',ARRAY['增肌','蛋白粉']::text[]),
    ('低FODMAP要坚持多久？','严格期通常是短期过程，症状改善后应在专业指导下逐项再引入，找到个人耐受范围，不建议长期无限制排除。',ARRAY['肠易激','FODMAP']::text[]),
    ('术后喝浓汤能补营养吗？','浓汤的蛋白质通常远低于汤里的肉，还可能脂肪和盐较高。应优先吃肉、蛋、奶、豆等，并按医嘱使用口服营养补充。',ARRAY['术后','浓汤']::text[]),
    ('纯素饮食怎样预防B12不足？','可靠来源主要是强化食品或B12补充剂，建议结合饮食史和化验结果由专业人员确定剂量并复查。',ARRAY['素食','B12']::text[]),
    ('孕期血糖高可以不吃主食吗？','不建议自行停掉主食。更合理的是控制份量、选择全谷杂豆并分配到三餐和加餐，同时按产科要求监测。',ARRAY['孕期','血糖','主食']::text[]),
    ('儿童偏瘦需要喝增重奶粉吗？','先看生长曲线、进食量和疾病因素。增重产品并非人人需要，应由儿科或营养专业人员评估后选择。',ARRAY['儿童','偏瘦']::text[]),
    ('高血压怎么减少盐？','少用酱油、蚝油和加工食品，逐步减盐并用醋、香辛料增味；若服药或有肾病，仍应遵循医生个体化要求。',ARRAY['高血压','减盐']::text[]),
    ('晚上吃水果会胖吗？','体重变化取决于长期总能量与饮食结构，不是由某个时刻单独决定。晚间如已吃足正餐，可控制份量避免无意识加餐。',ARRAY['水果','晚餐']::text[]),
    ('空腹运动减脂更快吗？','未必。长期效果主要取决于能量平衡和训练坚持度；空腹不适、低血糖风险或高强度训练时不宜勉强。',ARRAY['运动','空腹']::text[]),
    ('体重一天涨一公斤是长脂肪了吗？','通常不是。盐分、碳水、饮水、排便和经期都可造成水分波动，应观察7天趋势。',ARRAY['体重','波动']::text[]),
    ('营养咨询能代替医生看病吗？','不能。营养管理用于改善饮食与生活方式，不能替代疾病诊断、药物治疗或紧急医疗处理。',ARRAY['营养咨询','就医']::text[])
  ) AS x(question,answer,keywords);

  -- 六组自然咨询对话。
  FOR f IN SELECT * FROM (VALUES
    (v_staff_ids[2],'顾蔓','18810000301','孕期血糖和加餐怎么安排？','我孕24周，空腹血糖5.6，下午总是饿，可以吃什么？','先按产科要求继续监测。加餐可以选无糖酸奶搭配一小把坚果，或半个苹果加鸡蛋；份量要结合正餐和血糖记录，下次把三天餐后数据一起发我。'),
    (v_staff_ids[4],'姜文博','18810000302','增肌蛋白吃多了总胀气','每天蛋白吃到2.5克每公斤，最近训练后总胀气。','没必要硬顶这么高。先把总量下调并平均分到三到四餐，乳清暂停一周，改用鸡蛋、鱼和豆制品交替，观察症状与训练表现。'),
    (v_staff_ids[3],'谢安琪家长','18810000303','孩子不碰绿色蔬菜怎么办？','一看到青菜就推开，强喂会哭。','先暂停强喂。每周选一种蔬菜，用洗菜、摆盘、闻味、舔一口的阶梯方式接触；目标先是减少排斥，不要求马上吃完。'),
    (v_staff_ids[1],'丁一鸣','18810000307','痛风应酬怎么点菜？','这周有两场饭局，火锅和酒很难躲。','优先清汤锅但不喝汤，多选蔬菜、蛋和适量瘦肉，避开内脏和大量海鲜。酒最好不喝，可直接说正在复查尿酸；随身带水，别用含糖饮料代替。'),
    (v_staff_ids[1],'涂雅静','18810000306','低FODMAP再引入后又腹胀','昨天试了洋葱，晚上又胀了，是不是以后都不能吃？','一次反应不能直接判定终身不耐受。先记录份量和症状，恢复到稳定饮食，隔几天再从更小份量复测；若症状重或持续腹泻，请联系消化科。'),
    (v_staff_ids[5],'林澜','18810000324','晚睡后总想吃零食','加班到十一点就特别想吃甜的。','先保证晚餐有主食和蛋白，避免饿到深夜。加班时预备无糖酸奶或水果，回家先喝水、洗漱，把零食移出视线；这一周先观察睡眠和触发时间。')
  ) AS x(manager_id,visitor_name,visitor_phone,title,user_msg,assistant_msg)
  LOOP
    INSERT INTO public.manager_public_qa_sessions (
      manager_id,visitor_token,visitor_phone,visitor_name,first_message,message_count,last_active_at,created_at
    ) VALUES (
      f.manager_id,'demo-nutrition-'||substr(replace(gen_random_uuid()::text,'-',''),1,12),
      f.visitor_phone,f.visitor_name,f.user_msg,4,now()-(i%5||' hours')::interval,now()-(i%9||' days')::interval
    ) RETURNING id INTO v_session;
    INSERT INTO public.manager_public_qa_messages (session_id,role,content,created_at) VALUES
      (v_session,'user',f.user_msg,now()-interval '12 minutes'),
      (v_session,'assistant',f.assistant_msg,now()-interval '11 minutes'),
      (v_session,'user','明白了，我先按这个方法记录三天。',now()-interval '4 minutes'),
      (v_session,'assistant','好的，记录时把时间、份量和身体感受一起写上，复盘会更准确。',now()-interval '3 minutes');
  END LOOP;

  INSERT INTO public.reputation_categories (root_manager_id,name,sort_weight)
  VALUES (v_root,'孕产营养',50),(v_root,'儿童成长',40),(v_root,'慢病膳食',30),(v_root,'胃肠营养',20),(v_root,'运动营养',10)
  ON CONFLICT (root_manager_id,name) DO NOTHING;

  FOR f IN SELECT * FROM (VALUES
    (1,'孕期控糖终于不用挨饿了','营养师把主食和加餐重新分配后，血糖记录稳定多了，也没有以前那种一直饿的感觉。每次产检前还会提醒我准备数据，很细致。',5,860),
    (4,'妈妈术后从管饲过渡到正常吃饭','最有帮助的是把每餐份量拆得很清楚，不再靠浓汤“乱补”。复查白蛋白回升，全家终于松了一口气。',5,720),
    (6,'肠易激不是一张永久忌口单','以前照着网上清单什么都不敢吃。跟着做再引入后，找到了真正不耐受的份量，腹胀大概少了七成。',5,645),
    (7,'尿酸管理也能应付工作饭局','红绿灯卡和点菜话术很实用，三个月复查尿酸比之前稳定。偶尔还是馋火锅，但知道怎么控制了。',4,590),
    (8,'纯素五年后终于把营养吃明白','调整铁和维C的搭配，也按建议复查B12。两个月后血红蛋白恢复，训练时不再那么容易累。',5,810)
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
    '欢迎来到膳衡营养健康中心。请发送年龄、营养目标、疾病和用药情况，以及一日饮食记录，我们会安排对应营养师。','','',false
  ) ON CONFLICT (root_manager_id) DO NOTHING;

  INSERT INTO public.merchant_wecom_tips (root_manager_id,content,sort_order)
  SELECT v_root,x.content,x.ord FROM (VALUES
    (1,'今天的餐盘可以先做到一半蔬菜、四分之一优质蛋白、四分之一主食，再按个人情况调整。'),
    (2,'营养记录不必追求完美，写清时间、食物、份量和当时感受，连续三天就很有价值。'),
    (3,'浓汤不等于高蛋白，真正的蛋白质主要还在肉、蛋、奶、豆等食物里。'),
    (4,'孩子接触新食物可能需要很多次，允许只闻、只舔或吃一小口，比强迫更利于长期接受。'),
    (5,'痛风管理除了嘌呤，还要关注酒精、含糖饮料、饮水和体重变化。'),
    (6,'孕期不要自行极端控糖或停主食，任何明显异常都应结合产科检查和医生建议。'),
    (7,'训练后的恢复餐别只盯蛋白，碳水、补水和全天总能量同样影响表现。'),
    (8,'低FODMAP是分阶段工具，不是一辈子的禁食清单，再引入阶段非常重要。'),
    (9,'纯素饮食要特别留意维生素B12、铁、钙和蛋白质来源，定期复查更稳妥。'),
    (10,'食物不能替代药物或诊断；出现持续不适或指标明显异常，请及时联系医生。')
  ) AS x(ord,content)
  WHERE NOT EXISTS (SELECT 1 FROM public.merchant_wecom_tips t WHERE t.root_manager_id=v_root);

  INSERT INTO public.merchant_wecom_groups (root_manager_id,name,webhook_url,public_token,enabled,disabled_reason) VALUES
    (v_root,'演示｜孕产营养答疑群','https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-nutrition-0001','demo-nutrition-group-0001',false,'演示数据，不执行真实推送'),
    (v_root,'演示｜全家营养打卡群','https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-nutrition-0002','demo-nutrition-group-0002',false,'演示数据，不执行真实推送'),
    (v_root,'演示｜慢病膳食复盘群','https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-nutrition-0003','demo-nutrition-group-0003',false,'演示数据，不执行真实推送')
  ON CONFLICT (public_token) DO NOTHING;

  INSERT INTO public.merchant_wecom_contacts (
    root_manager_id,external_userid,type,name,follow_userids,source_state,last_message_at,first_seen_at
  )
  SELECT v_root,'demo_nutrition_'||lpad(n::text,3,'0'),'contact',pr.nickname||'（演示）',ARRAY['demo_nutrition_staff'],'demo',
         now()-(n||' hours')::interval,now()-(n*6||' days')::interval
  FROM generate_series(1,8) n JOIN public.profiles pr ON pr.id=v_client_ids[n]
  ON CONFLICT (root_manager_id,external_userid) DO NOTHING;
END
$demo$;

ALTER TABLE public.client_relations ENABLE TRIGGER trg_enforce_membership_client_limit;
ALTER TABLE public.manager_content_items ENABLE TRIGGER manager_content_items_before_write_trg;
