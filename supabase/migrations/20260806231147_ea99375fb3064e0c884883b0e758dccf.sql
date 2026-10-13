-- ============================================================================
-- 安全修复（紧急）第二批：其余 10 张匿名可读写的表
--
-- 已实测确认这些表匿名可读（含病史变更日志、健康维度评分、健康洞察、
-- 用户健康画像摘要，以及 custom_models 里的第三方模型 api_key），且匿名可写。
-- 成因同上：未启用行级安全 + anon/authenticated 持有全量表级权限。
--
-- 每张表的策略都按前端「现有真实调用点」设计，不收紧到超出现状，也不放宽：
--   health_dimension_scores  useHealthScores            → 严格自己（user_id = auth.uid()）
--   health_insights          AdminHealthInsights        → 本人可读 + 管理员全权
--   medical_history_logs     UserMedicalHistory         → 经 health_records 反查本人档案
--   user_lobster_agents      UserXiaokaiChat/OpenClaw   → 本人 + 管理员全权
--   user_lobster_skill_overrides AdminLobster           → 本人可读 + 管理员全权
--   manager_voice_profiles   ManagerVoiceSettings/UserProfile → 已登录可读、管理师改自己
--   custom_models            仅后台（含 api_key）        → 仅管理员，匿名彻底移除
--   lobster_knowledge_files  仅后台                     → 仅管理员，匿名彻底移除
--   lobster_config           UserSideDrawer 读开关       → 已登录可读、管理员可写
--   lobster_skills           仅后台                     → 已登录可读、管理员可写
--   openclaw_resources       OpenClawGuide 公开页        → 仅 is_active 行公开可读
-- ============================================================================


-- ─────────────────────────────────────────────────────────────
-- 一、用户自有健康数据：严格按 auth.uid() 归属
-- ─────────────────────────────────────────────────────────────

-- 1) health_dimension_scores（useHealthScores 只读写自己，含 upsert）
ALTER TABLE public.health_dimension_scores ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.health_dimension_scores FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.health_dimension_scores FROM authenticated;

DROP POLICY IF EXISTS hds_owner_select ON public.health_dimension_scores;
CREATE POLICY hds_owner_select ON public.health_dimension_scores
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS hds_owner_insert ON public.health_dimension_scores;
CREATE POLICY hds_owner_insert ON public.health_dimension_scores
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS hds_owner_update ON public.health_dimension_scores;
CREATE POLICY hds_owner_update ON public.health_dimension_scores
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS hds_admin_all ON public.health_dimension_scores;
CREATE POLICY hds_admin_all ON public.health_dimension_scores
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- 2) health_insights（后台管理页读写；本人保留只读）
ALTER TABLE public.health_insights ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.health_insights FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.health_insights FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_health_insights_user_id
  ON public.health_insights (user_id);

DROP POLICY IF EXISTS hi_owner_select ON public.health_insights;
CREATE POLICY hi_owner_select ON public.health_insights
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS hi_admin_all ON public.health_insights;
CREATE POLICY hi_admin_all ON public.health_insights
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- 3) medical_history_logs（只有 record_id，需经 health_records 反查归属人）
ALTER TABLE public.medical_history_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.medical_history_logs FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.medical_history_logs FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_medical_history_logs_record_field_changed
  ON public.medical_history_logs (record_id, field_name, changed_at DESC);

DROP POLICY IF EXISTS mhl_owner_select ON public.medical_history_logs;
CREATE POLICY mhl_owner_select ON public.medical_history_logs
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.health_records hr
      WHERE hr.id = medical_history_logs.record_id
        AND hr.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS mhl_owner_insert ON public.medical_history_logs;
CREATE POLICY mhl_owner_insert ON public.medical_history_logs
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.health_records hr
      WHERE hr.id = medical_history_logs.record_id
        AND hr.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS mhl_admin_all ON public.medical_history_logs;
CREATE POLICY mhl_admin_all ON public.medical_history_logs
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- 4) user_lobster_agents（本人读写 + 后台全权，后台有删除操作）
ALTER TABLE public.user_lobster_agents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_lobster_agents FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.user_lobster_agents FROM authenticated;

DROP POLICY IF EXISTS ula_owner_select ON public.user_lobster_agents;
CREATE POLICY ula_owner_select ON public.user_lobster_agents
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS ula_owner_insert ON public.user_lobster_agents;
CREATE POLICY ula_owner_insert ON public.user_lobster_agents
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS ula_owner_update ON public.user_lobster_agents;
CREATE POLICY ula_owner_update ON public.user_lobster_agents
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS ula_admin_all ON public.user_lobster_agents;
CREATE POLICY ula_admin_all ON public.user_lobster_agents
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- 5) user_lobster_skill_overrides（本人只读 + 后台全权）
ALTER TABLE public.user_lobster_skill_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_lobster_skill_overrides FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.user_lobster_skill_overrides FROM authenticated;

DROP POLICY IF EXISTS ulso_owner_select ON public.user_lobster_skill_overrides;
CREATE POLICY ulso_owner_select ON public.user_lobster_skill_overrides
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS ulso_admin_all ON public.user_lobster_skill_overrides;
CREATE POLICY ulso_admin_all ON public.user_lobster_skill_overrides
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- ─────────────────────────────────────────────────────────────
-- 二、管理师声音档案：已登录可读（用户端要用绑定管理师的音色），
--     但只有管理师本人能改自己的
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.manager_voice_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.manager_voice_profiles FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.manager_voice_profiles FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_manager_voice_profiles_manager_id
  ON public.manager_voice_profiles (manager_id);

DROP POLICY IF EXISTS mvp_authenticated_select ON public.manager_voice_profiles;
CREATE POLICY mvp_authenticated_select ON public.manager_voice_profiles
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS mvp_owner_write ON public.manager_voice_profiles;
CREATE POLICY mvp_owner_write ON public.manager_voice_profiles
  FOR ALL TO authenticated
  USING (manager_id = auth.uid())
  WITH CHECK (manager_id = auth.uid());

DROP POLICY IF EXISTS mvp_admin_all ON public.manager_voice_profiles;
CREATE POLICY mvp_admin_all ON public.manager_voice_profiles
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- ─────────────────────────────────────────────────────────────
-- 三、仅后台：custom_models 存有第三方模型 api_key，必须彻底关闭客户端可见性
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.custom_models ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.custom_models FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.custom_models FROM authenticated;

DROP POLICY IF EXISTS cm_admin_all ON public.custom_models;
CREATE POLICY cm_admin_all ON public.custom_models
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

COMMENT ON TABLE public.custom_models IS
  '自定义模型配置，api_key 列为明文第三方密钥：仅管理员可访问，anon 已彻底移除授权。新增读取入口前必须确认调用方是管理员。';


ALTER TABLE public.lobster_knowledge_files ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lobster_knowledge_files FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.lobster_knowledge_files FROM authenticated;

DROP POLICY IF EXISTS lkf_admin_all ON public.lobster_knowledge_files;
CREATE POLICY lkf_admin_all ON public.lobster_knowledge_files
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- ─────────────────────────────────────────────────────────────
-- 四、全局开关与技能目录：已登录可读、仅管理员可写
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.lobster_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lobster_config FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.lobster_config FROM authenticated;

DROP POLICY IF EXISTS lc_authenticated_select ON public.lobster_config;
CREATE POLICY lc_authenticated_select ON public.lobster_config
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS lc_admin_write ON public.lobster_config;
CREATE POLICY lc_admin_write ON public.lobster_config
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


ALTER TABLE public.lobster_skills ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lobster_skills FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE public.lobster_skills FROM authenticated;

DROP POLICY IF EXISTS ls_authenticated_select ON public.lobster_skills;
CREATE POLICY ls_authenticated_select ON public.lobster_skills
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS ls_admin_write ON public.lobster_skills;
CREATE POLICY ls_admin_write ON public.lobster_skills
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));


-- ─────────────────────────────────────────────────────────────
-- 五、openclaw_resources：/openclaw-guide 是未登录可访问的公开页，
--     因此只公开 is_active 的行，写入仅管理员
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.openclaw_resources ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.openclaw_resources FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.openclaw_resources FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_openclaw_resources_active
  ON public.openclaw_resources (is_active, category, created_at DESC)
  WHERE is_active = true;

DROP POLICY IF EXISTS ocr_public_select ON public.openclaw_resources;
CREATE POLICY ocr_public_select ON public.openclaw_resources
  FOR SELECT TO anon, authenticated
  USING (is_active = true);

DROP POLICY IF EXISTS ocr_admin_all ON public.openclaw_resources;
CREATE POLICY ocr_admin_all ON public.openclaw_resources
  FOR ALL TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));