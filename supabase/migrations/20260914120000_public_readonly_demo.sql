-- Public preview of the three explicitly synthetic enterprises. Never expose a manager session.
-- Seed a few weight-management conversations with a stable demo-only token.
DO $$
DECLARE v_session uuid;
BEGIN
  INSERT INTO public.manager_public_qa_sessions (manager_id,visitor_token,visitor_name,first_message,message_count)
  VALUES ('9d20bc6b-cbd4-4153-84e5-01e5b58f041f','demo-weight-public-1','王若溪','最近体重反复，晚饭是不是应该不吃主食？',4)
  ON CONFLICT (manager_id,visitor_token) DO NOTHING;
  SELECT id INTO v_session FROM public.manager_public_qa_sessions WHERE manager_id='9d20bc6b-cbd4-4153-84e5-01e5b58f041f' AND visitor_token='demo-weight-public-1';
  IF NOT EXISTS (SELECT 1 FROM public.manager_public_qa_messages WHERE session_id=v_session) THEN
    INSERT INTO public.manager_public_qa_messages (session_id,role,content) VALUES
      (v_session,'user','最近体重反复，晚饭是不是应该不吃主食？'),
      (v_session,'assistant','不用把主食完全停掉。先看最近一周平均体重，记录晚餐份量、睡眠和活动；晚餐可以有适量全谷杂粮，配足蔬菜和蛋白质。'),
      (v_session,'user','我经常加班，九点以后才吃晚饭。'),
      (v_session,'assistant','可以考虑傍晚先吃一份便携加餐，回家再吃清淡的正常晚餐。关键是全天总量和规律，不必因晚吃就补偿性节食。');
  END IF;

  INSERT INTO public.manager_public_qa_sessions (manager_id,visitor_token,visitor_name,first_message,message_count)
  VALUES ('9d20bc6b-cbd4-4153-84e5-01e5b58f041f','demo-weight-public-2','周子恒','运动后体重上升，是不是越练越胖？',4)
  ON CONFLICT (manager_id,visitor_token) DO NOTHING;
  SELECT id INTO v_session FROM public.manager_public_qa_sessions WHERE manager_id='9d20bc6b-cbd4-4153-84e5-01e5b58f041f' AND visitor_token='demo-weight-public-2';
  IF NOT EXISTS (SELECT 1 FROM public.manager_public_qa_messages WHERE session_id=v_session) THEN
    INSERT INTO public.manager_public_qa_messages (session_id,role,content) VALUES
      (v_session,'user','运动后体重上升，是不是越练越胖？'),
      (v_session,'assistant','刚开始运动时，肌肉储糖和水分变化会让体重暂时波动。先固定时段测量，结合腰围、体脂和两到四周趋势看。'),
      (v_session,'user','那我需要每天加大运动量吗？'),
      (v_session,'assistant','不建议突然加量。先保持每周规律活动，并留出恢复时间；如果有胸闷、眩晕等不适应暂停并就医。');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_public_readonly_demo(p_theme text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_root uuid;
  v_enterprise uuid;
  v_name text;
  v_data jsonb;
BEGIN
  CASE p_theme
    WHEN 'weight' THEN v_root := '9d20bc6b-cbd4-4153-84e5-01e5b58f041f'; v_name := '轻盈体重管理工作室';
    WHEN 'nutrition' THEN v_root := 'c6cc187c-3b13-40fc-befb-aa70594ebe3c'; v_name := '膳衡营养健康中心';
    WHEN 'chronic' THEN v_root := 'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e'; v_name := '安馨慢病健康管理中心';
    ELSE RETURN NULL;
  END CASE;

  SELECT enterprise_id INTO v_enterprise FROM public.managers WHERE id=v_root AND is_example=true;
  IF v_enterprise IS NULL THEN RETURN NULL; END IF;

  SELECT jsonb_build_object(
    'theme',p_theme,'name',v_name,
    'customer_count',(SELECT count(*) FROM public.client_relations cr JOIN public.profiles p ON p.id=cr.client_id JOIN auth.users u ON u.id=cr.client_id WHERE cr.root_manager_id=v_root AND (u.raw_app_meta_data->>'is_demo'='true' OR (p_theme='weight' AND p.phone LIKE '+852000000__'))),
    'weighing_count',(SELECT count(*) FROM public.body_compositions bc JOIN public.health_records hr ON hr.id=bc.record_id JOIN public.client_relations cr ON cr.client_id=hr.user_id JOIN public.profiles p ON p.id=cr.client_id JOIN auth.users u ON u.id=cr.client_id WHERE cr.root_manager_id=v_root AND (u.raw_app_meta_data->>'is_demo'='true' OR (p_theme='weight' AND p.phone LIKE '+852000000__')) AND (bc.metrics_meta->>'demo'='true' OR (p_theme='weight' AND bc.origin='manual'))),
    'survey_count',(SELECT count(*) FROM public.surveys s WHERE s.manager_id=v_root),
    'conversation_count',(SELECT count(*) FROM public.manager_public_qa_sessions s JOIN public.managers m ON m.id=s.manager_id WHERE m.enterprise_id=v_enterprise AND s.visitor_token LIKE 'demo-' || p_theme || '-%'),
    'order_count',(SELECT count(*) FROM public.orders o WHERE o.shop_manager_id_snapshot=v_root AND o.is_demo=true),
    'clients',coalesce((SELECT jsonb_agg(jsonb_build_object('name',coalesce(cr.customer_name,p.nickname),'notes',cr.notes,'last_contact',cr.last_contact_at,'follow_up',fr.content,'next_follow_up',fr.next_follow_up_at) ORDER BY cr.created_at DESC) FROM public.client_relations cr JOIN public.profiles p ON p.id=cr.client_id JOIN auth.users u ON u.id=cr.client_id LEFT JOIN LATERAL (SELECT f.content,f.next_follow_up_at FROM public.follow_up_records f WHERE f.client_relation_id=cr.id ORDER BY f.created_at DESC LIMIT 1) fr ON true WHERE cr.root_manager_id=v_root AND (u.raw_app_meta_data->>'is_demo'='true' OR (p_theme='weight' AND p.phone LIKE '+852000000__'))),'[]'::jsonb),
    'weighing',coalesce((SELECT jsonb_agg(jsonb_build_object('name',hr.name,'measured_at',bc.measured_at,'weight',bc.weight,'bmi',bc.bmi,'body_fat',bc.body_fat_percent,'muscle',bc.muscle_mass) ORDER BY bc.measured_at DESC) FROM public.body_compositions bc JOIN public.health_records hr ON hr.id=bc.record_id JOIN public.client_relations cr ON cr.client_id=hr.user_id JOIN public.profiles p ON p.id=cr.client_id JOIN auth.users u ON u.id=cr.client_id WHERE cr.root_manager_id=v_root AND (u.raw_app_meta_data->>'is_demo'='true' OR (p_theme='weight' AND p.phone LIKE '+852000000__')) AND (bc.metrics_meta->>'demo'='true' OR (p_theme='weight' AND bc.origin='manual'))),'[]'::jsonb),
    'conversations',coalesce((SELECT jsonb_agg(jsonb_build_object('visitor',s.visitor_name,'messages',coalesce((SELECT jsonb_agg(jsonb_build_object('role',msg.role,'content',msg.content) ORDER BY msg.created_at) FROM public.manager_public_qa_messages msg WHERE msg.session_id=s.id),'[]'::jsonb),'last_active',s.last_active_at) ORDER BY s.last_active_at DESC) FROM public.manager_public_qa_sessions s JOIN public.managers m ON m.id=s.manager_id WHERE m.enterprise_id=v_enterprise AND s.visitor_token LIKE 'demo-' || p_theme || '-%'),'[]'::jsonb),
    'surveys',coalesce((SELECT jsonb_agg(jsonb_build_object('title',s.title,'description',s.description,'questions',coalesce((SELECT jsonb_agg(q.title ORDER BY q.display_order) FROM public.survey_questions q WHERE q.survey_id=s.id),'[]'::jsonb)) ORDER BY s.created_at DESC) FROM public.surveys s WHERE s.manager_id=v_root),'[]'::jsonb),
    'qa',coalesce((SELECT jsonb_agg(jsonb_build_object('question',q.question,'answer',q.answer) ORDER BY q.created_at DESC) FROM public.enterprise_qa_faqs q WHERE q.enterprise_id=v_enterprise AND q.enabled=true),'[]'::jsonb),
    'orders',coalesce((SELECT jsonb_agg(jsonb_build_object('product',o.product_title_snapshot,'buyer',o.contact_name,'amount',o.total_amount_cents,'status',o.status,'created_at',o.created_at) ORDER BY o.created_at DESC) FROM public.orders o WHERE o.shop_manager_id_snapshot=v_root AND o.is_demo=true),'[]'::jsonb),
    'products',coalesce((SELECT jsonb_agg(jsonb_build_object('title',p.title,'subtitle',p.subtitle,'cover',p.cover_image_url,'price',sku.price_cents) ORDER BY p.sort_weight DESC) FROM public.products p LEFT JOIN LATERAL (SELECT s.price_cents FROM public.product_skus s WHERE s.product_id=p.id AND s.is_default=true LIMIT 1) sku ON true WHERE p.owner_manager_id=v_root AND p.status='active'),'[]'::jsonb),
    'courses',coalesce((SELECT jsonb_agg(jsonb_build_object('title',c.title,'description',c.description,'cover',c.cover_image_url) ORDER BY c.sort_weight DESC) FROM public.enterprise_courses c WHERE c.enterprise_id=v_enterprise AND c.is_published=true),'[]'::jsonb),
    'content',coalesce((SELECT jsonb_agg(jsonb_build_object('title',c.title,'type',c.content_type,'cover',c.cover_url) ORDER BY c.sort_weight DESC) FROM public.manager_content_items c WHERE c.root_manager_id=v_root AND c.is_published=true AND c.moderation_status='passed'),'[]'::jsonb)
  ) INTO v_data;
  RETURN v_data;
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_readonly_demo(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_readonly_demo(text) TO anon, authenticated;

-- Keep the public projection free of identifying/contact/medical/detail keys.
DO $$
DECLARE v jsonb;
BEGIN
  v := public.get_public_readonly_demo('weight');
  IF public.get_public_readonly_demo('not-a-demo') IS NOT NULL
     OR v ?| ARRAY['phone','email','password','client_id','auth_id'] THEN
    RAISE EXCEPTION 'public demo boundary check failed';
  END IF;
END;
$$;
