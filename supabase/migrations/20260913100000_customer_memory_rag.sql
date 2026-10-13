-- ============================================================================
-- 客户级 RAG 长期记忆 + 员工智能体角色（健康管理师/销售）+ 推荐话术
-- 1) 启用 pgvector，客户记忆分块表（HNSW cosine，按租户+外部联系人隔离）
-- 2) 客户话术库构建状态表（手动创建/增量更新游标）
-- 3) 推荐话术生成日志表
-- 4) managers 增加 agent_role / agent_goal / agent_redlines，贯通克隆/发布
-- 5) RPC：状态查询 / 构建开始 / 分块提交 / 向量检索 / 日志写入 / 标记已复制
--
-- 向量维度：DashScope text-embedding-v3（dimensions=1024）
-- ============================================================================

-- 1. pgvector ----------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. 客户记忆分块表 -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customer_memory_chunks (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id   uuid NOT NULL,
  external_userid   text NOT NULL,
  profile_id        uuid,
  -- profile 客户画像 / health 健康档案(含家人) / event 跟进事件 / chat 单聊消息
  source_type       text NOT NULL CHECK (source_type IN ('profile','health','event','chat')),
  -- 业务去重键：非 chat 为 业务类型:业务id（如 health:<record_id>）；chat 为 chat:<首条msgid>
  source_ref        text NOT NULL DEFAULT '',
  content           text NOT NULL,
  embedding         vector(1024),
  meta              jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_memory_chunks_ref
  ON public.customer_memory_chunks (root_manager_id, external_userid, source_type, source_ref);

CREATE INDEX IF NOT EXISTS idx_customer_memory_chunks_customer
  ON public.customer_memory_chunks (root_manager_id, external_userid, source_type);

CREATE INDEX IF NOT EXISTS idx_customer_memory_chunks_hnsw
  ON public.customer_memory_chunks
  USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

ALTER TABLE public.customer_memory_chunks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_memory_chunks FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_memory_chunks TO service_role;

-- 3. 客户话术库构建状态 -------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customer_memory_status (
  root_manager_id      uuid NOT NULL,
  external_userid      text NOT NULL,
  status               text NOT NULL DEFAULT 'none'
                         CHECK (status IN ('none','building','ready','error')),
  chunk_count          integer NOT NULL DEFAULT 0,
  last_synced_msgtime  bigint NOT NULL DEFAULT 0,
  last_error           text,
  built_by             uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (root_manager_id, external_userid)
);

ALTER TABLE public.customer_memory_status ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_memory_status FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON public.customer_memory_status TO service_role;

-- 4. 推荐话术日志 -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wecom_reply_suggestion_logs (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id        uuid NOT NULL,
  manager_id             uuid,
  actor_id               uuid,
  scene                  text NOT NULL DEFAULT 'single' CHECK (scene IN ('single','group')),
  roomid                 text,
  external_userid        text,
  target_external_userid text,
  target_name            text,
  agent_role             text,
  query_text             text,
  suggestions            jsonb NOT NULL DEFAULT '[]'::jsonb,
  cache_hit              boolean NOT NULL DEFAULT false,
  latency_ms             integer,
  copied_index           integer,
  copied_at              timestamptz,
  error                  text,
  created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wecom_reply_suggestion_logs_created
  ON public.wecom_reply_suggestion_logs (root_manager_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_reply_suggestion_logs_customer
  ON public.wecom_reply_suggestion_logs (root_manager_id, external_userid, created_at DESC);

ALTER TABLE public.wecom_reply_suggestion_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_reply_suggestion_logs FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON public.wecom_reply_suggestion_logs TO service_role;

-- 5. managers 增加智能体角色/目的/红线 ----------------------------------------
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS agent_role text NOT NULL DEFAULT 'health_manager',
  ADD COLUMN IF NOT EXISTS agent_goal text,
  ADD COLUMN IF NOT EXISTS agent_redlines text;

-- 5.1 克隆时带上新字段
CREATE OR REPLACE FUNCTION public.clone_manager_agent(
  p_source_manager_id uuid,
  p_target_manager_id uuid,
  p_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_config jsonb;
  v_agent_id uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN json_build_object('error', '未登录'); END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
    RETURN json_build_object('error', '无智能体管理权限');
  END IF;
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN RETURN json_build_object('error', '无企业归属'); END IF;

  IF NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p_source_manager_id AND m.enterprise_id = v_ent) THEN
    RETURN json_build_object('error', '源健管师不在本企业');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_target_manager_id AND p.enterprise_id = v_ent) THEN
    RETURN json_build_object('error', '目标健管师不在本企业');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p_target_manager_id) THEN
    RETURN json_build_object('error', '目标健管师尚未建立智能体，请先在健管师管理里创建');
  END IF;

  SELECT jsonb_build_object(
    'business_name', m.business_name, 'tagline', m.tagline, 'intro_personal', m.intro_personal,
    'intro_company', m.intro_company, 'digital_avatar_image_url', m.digital_avatar_image_url,
    'credentials', m.credentials, 'knowledge_system_prompt', m.knowledge_system_prompt,
    'knowledge_model', m.knowledge_model, 'public_qa_enabled', m.public_qa_enabled,
    'public_qa_welcome_message', m.public_qa_welcome_message, 'public_qa_lead_capture_mode', m.public_qa_lead_capture_mode,
    'agent_role', m.agent_role, 'agent_goal', m.agent_goal, 'agent_redlines', m.agent_redlines
  ) INTO v_config FROM public.managers m WHERE m.id = p_source_manager_id;

  INSERT INTO public.health_manager_agents (manager_id, enterprise_id, name, status, is_active, config, source_manager_id)
  VALUES (p_target_manager_id, v_ent, COALESCE(NULLIF(trim(p_name), ''), '克隆草稿'), 'draft', false, v_config, p_source_manager_id)
  RETURNING id INTO v_agent_id;

  RETURN json_build_object('success', true, 'agent_id', v_agent_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.clone_manager_agent(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clone_manager_agent(uuid, uuid, text) TO authenticated;

-- 5.2 发布时把角色/目的/红线应用到 managers
CREATE OR REPLACE FUNCTION public.publish_manager_agent(p_agent_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_agent record;
BEGIN
  IF v_uid IS NULL THEN RETURN json_build_object('error', '未登录'); END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
    RETURN json_build_object('error', '无智能体管理权限');
  END IF;
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;

  SELECT * INTO v_agent FROM public.health_manager_agents WHERE id = p_agent_id AND enterprise_id = v_ent;
  IF NOT FOUND THEN
    RETURN json_build_object('error', '草稿不存在');
  END IF;
  IF v_agent.status <> 'draft' THEN
    RETURN json_build_object('error', '该版本不是草稿');
  END IF;

  UPDATE public.managers m
     SET business_name = COALESCE(v_agent.config->>'business_name', m.business_name),
         tagline = COALESCE(v_agent.config->>'tagline', m.tagline),
         intro_personal = COALESCE(v_agent.config->>'intro_personal', m.intro_personal),
         intro_company = COALESCE(v_agent.config->>'intro_company', m.intro_company),
         digital_avatar_image_url = COALESCE(v_agent.config->>'digital_avatar_image_url', m.digital_avatar_image_url),
         credentials = COALESCE((v_agent.config->'credentials')::text[], m.credentials),
         knowledge_system_prompt = COALESCE(v_agent.config->>'knowledge_system_prompt', m.knowledge_system_prompt),
         knowledge_model = COALESCE(v_agent.config->>'knowledge_model', m.knowledge_model),
         public_qa_enabled = COALESCE((v_agent.config->>'public_qa_enabled')::boolean, m.public_qa_enabled),
         public_qa_welcome_message = COALESCE(v_agent.config->>'public_qa_welcome_message', m.public_qa_welcome_message),
         public_qa_lead_capture_mode = COALESCE(v_agent.config->>'public_qa_lead_capture_mode', m.public_qa_lead_capture_mode),
         agent_role = COALESCE(NULLIF(btrim(v_agent.config->>'agent_role'), ''), m.agent_role),
         agent_goal = COALESCE(v_agent.config->>'agent_goal', m.agent_goal),
         agent_redlines = COALESCE(v_agent.config->>'agent_redlines', m.agent_redlines),
         updated_at = now()
   WHERE m.id = v_agent.manager_id;

  UPDATE public.health_manager_agents SET is_active = false, updated_at = now()
   WHERE manager_id = v_agent.manager_id AND is_active = true AND id <> p_agent_id;

  UPDATE public.health_manager_agents SET status = 'published', is_active = true, updated_at = now()
   WHERE id = p_agent_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.publish_manager_agent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publish_manager_agent(uuid) TO authenticated;

-- 6. RPC：查询客户话术库状态（前端用，走登录用户权限） -------------------------
CREATE OR REPLACE FUNCTION public.get_customer_memory_status(p_external_userid text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_contact public.merchant_wecom_contacts;
  v_row public.customer_memory_status;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_pro_module_open(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_customers', v_uid) THEN
    RAISE EXCEPTION '没有访问客户库的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_contact
  FROM public.merchant_wecom_contacts
  WHERE root_manager_id = v_root AND external_userid = btrim(COALESCE(p_external_userid, ''));
  IF v_contact.id IS NULL THEN
    RAISE EXCEPTION '客户不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    IF COALESCE(btrim(COALESCE(v_my_userid, '')), '') = ''
       OR NOT (
         v_contact.follow_userids @> ARRAY[btrim(v_my_userid)]
         OR v_contact.lost_userid = btrim(v_my_userid)
       ) THEN
      RAISE EXCEPTION '客户不存在或无权查看' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT * INTO v_row
  FROM public.customer_memory_status
  WHERE root_manager_id = v_root AND external_userid = v_contact.external_userid;

  RETURN jsonb_build_object(
    'externalUserid', v_contact.external_userid,
    'status', COALESCE(v_row.status, 'none'),
    'chunkCount', COALESCE(v_row.chunk_count, 0),
    'lastSyncedMsgtime', COALESCE(v_row.last_synced_msgtime, 0),
    'lastError', v_row.last_error,
    'updatedAt', v_row.updated_at,
    'moduleOpen', true,
    'archiveReadable', public.wecom_archive_readable(v_root)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_customer_memory_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_customer_memory_status(text) TO authenticated;

-- 7. RPC：EF 侧开始构建（service_role 调用，p_actor 为操作者，做权限校验） ----
CREATE OR REPLACE FUNCTION public.begin_customer_memory_build(
  p_root uuid,
  p_external_userid text,
  p_actor uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor_root uuid;
  v_is_admin boolean;
  v_actor_userid text;
  v_contact public.merchant_wecom_contacts;
BEGIN
  IF p_root IS NULL OR btrim(COALESCE(p_external_userid, '')) = '' OR p_actor IS NULL THEN
    RETURN json_build_object('error', '参数不完整');
  END IF;

  v_actor_root := public.get_enterprise_root_manager_id(p_actor);
  IF v_actor_root IS DISTINCT FROM p_root THEN
    RETURN json_build_object('error', '无权操作该客户');
  END IF;
  IF NOT public.wecom_pro_module_open(p_root) THEN
    RETURN json_build_object('error', '企微助手 Pro 尚未开通');
  END IF;

  SELECT * INTO v_contact
  FROM public.merchant_wecom_contacts
  WHERE root_manager_id = p_root AND external_userid = btrim(p_external_userid);
  IF v_contact.id IS NULL THEN
    RETURN json_build_object('error', '客户不存在');
  END IF;

  v_is_admin := public.is_enterprise_admin(p_actor);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_actor_userid FROM public.profiles WHERE id = p_actor;
    IF COALESCE(btrim(COALESCE(v_actor_userid, '')), '') = ''
       OR NOT v_contact.follow_userids @> ARRAY[btrim(v_actor_userid)] THEN
      RETURN json_build_object('error', '无权操作该客户');
    END IF;
  END IF;

  INSERT INTO public.customer_memory_status (root_manager_id, external_userid, status, last_error, built_by, updated_at)
  VALUES (p_root, v_contact.external_userid, 'building', NULL, p_actor, now())
  ON CONFLICT (root_manager_id, external_userid)
  DO UPDATE SET status = 'building', last_error = NULL, built_by = EXCLUDED.built_by, updated_at = now();

  RETURN json_build_object('success', true, 'external_userid', v_contact.external_userid, 'profile_id', v_contact.profile_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.begin_customer_memory_build(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.begin_customer_memory_build(uuid, text, uuid) TO service_role;

-- 8. RPC：EF 侧提交分块（非 chat 全量重灌；chat 幂等增量插入） ---------------
-- p_non_chat / p_chat 元素：{source_type, source_ref, content, embedding:[...1024], meta:{}}
CREATE OR REPLACE FUNCTION public.commit_customer_memory_chunks(
  p_root uuid,
  p_external_userid text,
  p_profile_id uuid,
  p_non_chat jsonb,
  p_chat jsonb,
  p_synced_msgtime bigint,
  p_status text,
  p_error text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_count integer;
  v_synced bigint;
BEGIN
  IF p_root IS NULL OR btrim(COALESCE(p_external_userid, '')) = '' THEN
    RETURN json_build_object('error', '参数不完整');
  END IF;
  IF COALESCE(p_status, 'ready') NOT IN ('ready','error') THEN
    RETURN json_build_object('error', '非法状态');
  END IF;

  -- 非聊天块（画像/健康/事件）每次全量重灌
  DELETE FROM public.customer_memory_chunks
  WHERE root_manager_id = p_root
    AND external_userid = btrim(p_external_userid)
    AND source_type <> 'chat';

  INSERT INTO public.customer_memory_chunks
    (root_manager_id, external_userid, profile_id, source_type, source_ref, content, embedding, meta)
  SELECT p_root, btrim(p_external_userid), p_profile_id,
         c->>'source_type', COALESCE(c->>'source_ref', ''), c->>'content',
         CASE WHEN c ? 'embedding' THEN (c->>'embedding')::public.vector ELSE NULL END,
         COALESCE(c->'meta', '{}'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_non_chat, '[]'::jsonb)) AS c
  WHERE COALESCE(c->>'source_type','') IN ('profile','health','event')
    AND btrim(COALESCE(c->>'content','')) <> '';

  -- 聊天块增量插入，冲突跳过（source_ref 幂等）
  INSERT INTO public.customer_memory_chunks
    (root_manager_id, external_userid, profile_id, source_type, source_ref, content, embedding, meta)
  SELECT p_root, btrim(p_external_userid), p_profile_id, 'chat',
         COALESCE(c->>'source_ref', ''), c->>'content',
         CASE WHEN c ? 'embedding' THEN (c->>'embedding')::public.vector ELSE NULL END,
         COALESCE(c->'meta', '{}'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_chat, '[]'::jsonb)) AS c
  WHERE btrim(COALESCE(c->>'content','')) <> ''
  ON CONFLICT (root_manager_id, external_userid, source_type, source_ref) DO NOTHING;

  SELECT count(*), COALESCE(max(last_synced_msgtime), 0)
    INTO v_count, v_synced
  FROM public.customer_memory_status
  WHERE root_manager_id = p_root AND external_userid = btrim(p_external_userid);

  INSERT INTO public.customer_memory_status
    (root_manager_id, external_userid, status, chunk_count, last_synced_msgtime, last_error, updated_at)
  VALUES (
    p_root, btrim(p_external_userid), COALESCE(p_status, 'ready'),
    (SELECT count(*) FROM public.customer_memory_chunks
      WHERE root_manager_id = p_root AND external_userid = btrim(p_external_userid)),
    CASE WHEN COALESCE(p_status,'ready') = 'ready'
         THEN greatest(COALESCE(p_synced_msgtime, 0), COALESCE(v_synced, 0))
         ELSE COALESCE(v_synced, 0) END,
    CASE WHEN COALESCE(p_status,'ready') = 'error' THEN left(COALESCE(p_error,'未知错误'), 500) ELSE NULL END,
    now()
  )
  ON CONFLICT (root_manager_id, external_userid)
  DO UPDATE SET
    status = EXCLUDED.status,
    chunk_count = EXCLUDED.chunk_count,
    last_synced_msgtime = EXCLUDED.last_synced_msgtime,
    last_error = EXCLUDED.last_error,
    updated_at = now();

  SELECT count(*) INTO v_count FROM public.customer_memory_chunks
  WHERE root_manager_id = p_root AND external_userid = btrim(p_external_userid);

  RETURN json_build_object('success', true, 'chunk_count', v_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.commit_customer_memory_chunks(uuid, text, uuid, jsonb, jsonb, bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.commit_customer_memory_chunks(uuid, text, uuid, jsonb, jsonb, bigint, text, text) TO service_role;

-- 9. RPC：EF 侧向量检索（cosine 相似度，返回 topK） ---------------------------
CREATE OR REPLACE FUNCTION public.search_customer_memory(
  p_root uuid,
  p_external_userid text,
  p_embedding text,
  p_topk integer DEFAULT 5
)
RETURNS TABLE (
  id uuid,
  source_type text,
  source_ref text,
  content text,
  meta jsonb,
  score real
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT c.id, c.source_type, c.source_ref, c.content, c.meta,
         (1 - (c.embedding OPERATOR(public.<=>) p_embedding::public.vector))::real AS score
  FROM public.customer_memory_chunks c
  WHERE c.root_manager_id = p_root
    AND c.external_userid = btrim(p_external_userid)
    AND c.embedding IS NOT NULL
  ORDER BY c.embedding OPERATOR(public.<=>) p_embedding::public.vector
  LIMIT GREATEST(LEAST(COALESCE(p_topk, 5), 20), 1);
$function$;

REVOKE ALL ON FUNCTION public.search_customer_memory(uuid, text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_customer_memory(uuid, text, text, integer) TO service_role;

-- 10. RPC：标记某条话术已复制 -----------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_wecom_suggestion_copied(
  p_log_id uuid,
  p_index integer
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN json_build_object('error', '未登录'); END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  UPDATE public.wecom_reply_suggestion_logs
     SET copied_index = GREATEST(COALESCE(p_index, 0), 0),
         copied_at = now()
   WHERE id = p_log_id AND root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN json_build_object('error', '记录不存在');
  END IF;
  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_wecom_suggestion_copied(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_wecom_suggestion_copied(uuid, integer) TO authenticated;

-- 11. 通知 PostgREST 刷新 ----------------------------------------------------
NOTIFY pgrst, 'reload schema';
