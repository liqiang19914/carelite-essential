
-- 健康维度评分表，存储五维健康雷达图的各维度得分
CREATE TABLE health_dimension_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  dimension varchar(20) NOT NULL,
  score integer NOT NULL DEFAULT 0,
  source varchar(20) NOT NULL DEFAULT 'self_assessment',
  detail_json jsonb DEFAULT '{}',
  assessed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT health_dimension_scores_unique UNIQUE(user_id, dimension),
  CONSTRAINT health_dimension_scores_score_range CHECK (score >= 0 AND score <= 100),
  CONSTRAINT health_dimension_scores_dimension_valid CHECK (dimension IN ('diet', 'sleep', 'emotion', 'fitness', 'metabolism'))
);

CREATE INDEX idx_health_dimension_scores_user_id ON health_dimension_scores(user_id);

COMMENT ON TABLE health_dimension_scores IS '健康维度评分表，存储膳食、睡眠、情绪、运动、代谢五个维度的健康得分';
COMMENT ON COLUMN health_dimension_scores.dimension IS '维度标识: diet=膳食营养, sleep=睡眠质量, emotion=情绪状态, fitness=运动活动, metabolism=代谢指标';
COMMENT ON COLUMN health_dimension_scores.source IS '得分来源: self_assessment=自评问卷, auto_vital=体征自动计算, ai_analysis=AI分析';
COMMENT ON COLUMN health_dimension_scores.detail_json IS '评分明细JSON，存储各子项得分';
