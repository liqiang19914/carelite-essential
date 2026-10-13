CREATE OR REPLACE FUNCTION public.provision_system_health_managers(
  p_root_id uuid,
  p_enterprise_id uuid,
  p_company_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_root_role text;
  v_key text;
  v_new_id uuid;
  i integer;
  v_keys text[] := ARRAY['chronic','gut','weight','sleep','fitness','mother_baby'];
  v_names text[] := ARRAY['陈淑华','周子健','林晓芸','王静怡','郑凯','苏婉清'];
  v_tags text[] := ARRAY[
    '慢病全程管理 · 用药饮食双把关',
    '胃肠调理 · 吃出舒服的每一天',
    '科学减重 · 不挨饿不掉代谢',
    '睡眠与情绪 · 找回一夜好眠',
    '运动处方 · 安全练出好状态',
    '母婴护理 · 从备孕到育儿'
  ];
  v_intros text[] := ARRAY[
    '擅长高血压、高血糖、高血脂等慢病的生活方式管理，配合医嘱制定饮食与作息方案。',
    '擅长慢性胃炎、反酸烧心、腹胀便秘等胃肠问题的饮食调理与习惯重建。',
    '擅长体重管理与体成分优化，制定可坚持的饮食与运动组合方案。',
    '擅长失眠、浅睡、多梦与压力型睡眠问题的非药物改善方案。',
    '擅长运动风险评估与运动处方制定，帮助久坐人群安全恢复运动。',
    '擅长孕期营养、产后恢复与婴幼儿喂养指导，陪伴家庭健康起步。'
  ];
  v_avatars text[] := ARRAY[
    'https://b.ux-cdn.com/uxarts-agent/20260821/745babcb01b849b184abad51e152cabe.png',
    'https://b.ux-cdn.com/uxarts-agent/20260821/e1ed0aa0168c49fc9d4b7f787c09587e.png',
    'https://b.ux-cdn.com/uxarts-agent/20260821/02a6cf91c0314a72a51f5bc5817e8902.png',
    'https://b.ux-cdn.com/uxarts-agent/20260821/78bcbcb46c594974a34d91cb030a93ed.png',
    'https://b.ux-cdn.com/uxarts-agent/20260821/327c7753dd384fac897aff534189ea46.png',
    'https://b.ux-cdn.com/uxarts-agent/20260821/9c205eeb3ef543cbae74afe3c9969c68.png'
  ];
BEGIN
  IF p_root_id IS NULL OR p_enterprise_id IS NULL THEN
    RAISE EXCEPTION '企业根与归属企业不能为空' USING ERRCODE = 'P0002';
  END IF;

  SELECT p.role INTO v_root_role
    FROM public.profiles p
   WHERE p.id = p_root_id;
  IF v_root_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION '企业根不是有效管理师' USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('sysmgr:' || p_enterprise_id::text, 0));

  FOR i IN 1..6 LOOP
    v_key := v_keys[i];

    IF EXISTS (
      SELECT 1 FROM public.managers m
      WHERE m.enterprise_id = p_enterprise_id AND m.system_default_key = v_key
    ) THEN
      CONTINUE;
    END IF;

    v_new_id := gen_random_uuid();

    -- 顺序约束：managers.id 有外键指向 auth.users；auth.users 的 handle_new_user
    -- 触发器会自动先建一行基础 profile，随后用 UPDATE 补全身份字段。
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change_token_new, email_change, banned_until
    ) VALUES (
      '00000000-0000-0000-0000-000000000000', v_new_id,
      'authenticated', 'authenticated',
      'sys-' || v_key || '-' || left(v_new_id::text, 8) || '@kaitong.local',
      extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')),
      NOW(),
      '{"provider": "system", "providers": ["system"], "is_system_default": true}'::jsonb,
      jsonb_build_object('nickname', v_names[i], 'is_system_default', true),
      NOW(), NOW(), '', '', '', '',
      'infinity'::timestamptz
    );

    INSERT INTO public.managers (
      id, business_name, certification_status, membership_level,
      company_name, digital_avatar_image_url, intro_personal, tagline,
      credentials, invite_code, short_code,
      is_system_default, system_default_key, enterprise_id,
      created_at, updated_at
    ) VALUES (
      v_new_id, v_names[i], 'approved', 'free',
      p_company_name, v_avatars[i], v_intros[i], v_tags[i],
      CASE WHEN v_key = 'mother_baby'
        THEN ARRAY['健康管理师','母婴护理师']
        ELSE ARRAY['健康管理师','公共营养师'] END,
      generate_manager_invite_code(), generate_manager_short_code(),
      true, v_key, p_enterprise_id,
      NOW(), NOW()
    );

    UPDATE public.profiles
       SET nickname = v_names[i],
           avatar_url = v_avatars[i],
           role = 'manager',
           sub_role = 'health_manager',
           enterprise_id = p_enterprise_id,
           parent_manager_id = p_root_id,
           is_verified = true,
           is_disabled = false
     WHERE id = v_new_id;
  END LOOP;
END;
$function$;