-- ============================================================================
-- 健康饮食导图（六型 SDGNCA）— 平台级一级功能：数据模型
-- ============================================================================

-- 1) 模板表：题目 / 评分权重 / 六型报告内容 + 客户确认闸门
CREATE TABLE IF NOT EXISTS public.diet_map_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  map_key text NOT NULL,
  title text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'draft',
  questions jsonb NOT NULL DEFAULT '[]'::jsonb,
  scoring jsonb NOT NULL DEFAULT '{}'::jsonb,
  report jsonb NOT NULL DEFAULT '{}'::jsonb,
  config_version integer NOT NULL DEFAULT 1,
  scoring_confirmed boolean NOT NULL DEFAULT false,
  scoring_confirmed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  scoring_confirmed_at timestamptz,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT diet_map_templates_status_check
    CHECK (status IN ('draft', 'published', 'archived'))
);

CREATE UNIQUE INDEX IF NOT EXISTS diet_map_templates_map_key_key
  ON public.diet_map_templates (map_key);

COMMENT ON TABLE public.diet_map_templates IS
  '健康饮食导图模板：25 题问卷配置、六型声明式评分权重、六型报告内容。scoring_confirmed 为客户确认闸门，未确认时任何评估只落 pending_config，不出饮食建议。';
COMMENT ON COLUMN public.diet_map_templates.scoring IS
  '声明式权重表，不含可执行表达式：{ weights: { <questionCode>: { <optionCode>: { S:int,...A:int } } }, tieBreak: null | ["S","D",...], isReference: bool }';
COMMENT ON COLUMN public.diet_map_templates.report IS
  '六型报告内容：{ types: { S: { color, system, traits[], strategy[], meals[{label, percent, note}], confidence: confident|needs_review } , ... } }';
COMMENT ON COLUMN public.diet_map_templates.scoring_confirmed IS
  '是否已由客户方（OEM 品牌方）确认评分规则。false 时评估强制落 pending_config，前端不展示任何分型结论与饮食建议。';

-- 2) 开放表：按企业根管理师开放（员工自动继承）
CREATE TABLE IF NOT EXISTS public.diet_map_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id uuid NOT NULL REFERENCES public.diet_map_templates(id) ON DELETE CASCADE,
  root_manager_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_enabled boolean NOT NULL DEFAULT true,
  granted_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  notes text NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS diet_map_grants_template_root_key
  ON public.diet_map_grants (template_id, root_manager_id);

CREATE INDEX IF NOT EXISTS idx_diet_map_grants_root_enabled
  ON public.diet_map_grants (root_manager_id, is_enabled, template_id);

CREATE INDEX IF NOT EXISTS idx_diet_map_grants_template
  ON public.diet_map_grants (template_id, is_enabled);

COMMENT ON TABLE public.diet_map_grants IS
  '健康饮食导图按企业根商户开放。root_manager_id 必须是企业 boss（profiles.parent_manager_id IS NULL），员工与其客户自动继承。撤销开放只隐藏入口，不删除历史评估。';

-- 3) 评估表：按家庭成员档案（record_id）归属，一次评估一行历史
CREATE TABLE IF NOT EXISTS public.diet_map_assessments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id uuid NOT NULL REFERENCES public.diet_map_templates(id) ON DELETE RESTRICT,
  config_version integer NOT NULL DEFAULT 1,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  record_id uuid NOT NULL REFERENCES public.health_records(id) ON DELETE CASCADE,
  manager_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  answers jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending_config',
  type_code text NOT NULL DEFAULT '',
  scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  report_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  prefill_meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_composition_id uuid REFERENCES public.body_compositions(id) ON DELETE SET NULL,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT diet_map_assessments_status_check
    CHECK (status IN ('scored', 'pending_config', 'pending_tie')),
  CONSTRAINT diet_map_assessments_scored_needs_type
    CHECK (status <> 'scored' OR type_code <> ''),
  CONSTRAINT diet_map_assessments_type_code_check
    CHECK (type_code = '' OR type_code IN ('S', 'D', 'G', 'N', 'C', 'A'))
);

CREATE INDEX IF NOT EXISTS idx_diet_map_assessments_record_time
  ON public.diet_map_assessments (record_id, submitted_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_diet_map_assessments_manager_time
  ON public.diet_map_assessments (manager_id, submitted_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_diet_map_assessments_user_time
  ON public.diet_map_assessments (user_id, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_diet_map_assessments_template_status
  ON public.diet_map_assessments (template_id, status, id);

COMMENT ON TABLE public.diet_map_assessments IS
  '健康饮食导图评估记录。按 record_id（家庭成员档案）归属而非账号，支持一账号多成员各自分型。每次评估插一行新历史，不覆盖旧记录；「当前分型」= 该 record_id 下 submitted_at 最新的一行。';
COMMENT ON COLUMN public.diet_map_assessments.status IS
  'scored=已评定；pending_config=评分规则未配置或未经客户方确认；pending_tie=多型同分且未设置显式平局序';
COMMENT ON COLUMN public.diet_map_assessments.prefill_meta IS
  '预填来源与用户改写留痕，仅用于展示与追溯，不参与评分：{ <questionCode>: { source, value, overridden: bool, measuredAt } }';

-- 4) 覆盖率统计与 RLS 判定用索引
CREATE INDEX IF NOT EXISTS idx_client_relations_manager_client_status
  ON public.client_relations (manager_id, client_id, status, id);

ALTER TABLE public.diet_map_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diet_map_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diet_map_assessments ENABLE ROW LEVEL SECURITY;