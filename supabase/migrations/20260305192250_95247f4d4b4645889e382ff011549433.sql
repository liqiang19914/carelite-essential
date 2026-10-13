
-- 健康洞察表：存储 AI 提取的结构化健康信息
CREATE TABLE health_insights (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  category VARCHAR(30) NOT NULL,
  title VARCHAR(200) NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  severity VARCHAR(10) NOT NULL DEFAULT 'info',
  source_type VARCHAR(20) NOT NULL,
  source_snippet TEXT NOT NULL DEFAULT '',
  analyzed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE health_insights IS '健康洞察表，存储管理员手动触发AI分析后提取的结构化健康信息';
COMMENT ON COLUMN health_insights.category IS '分类: condition=疾病诊断, symptom=症状, medication=用药, allergy=过敏, vital_abnormal=体征异常, diet_issue=饮食问题, sleep_issue=睡眠问题, risk=风险提示, lifestyle=生活习惯';
COMMENT ON COLUMN health_insights.severity IS '严重程度: info=一般, warning=需关注, critical=严重';
COMMENT ON COLUMN health_insights.source_type IS '数据来源: chat=对话, report=体检报告, vital=体征打卡, record=健康档案';
COMMENT ON COLUMN health_insights.source_snippet IS '原始数据摘录，用于溯源';

CREATE INDEX idx_health_insights_user_id ON health_insights(user_id);
CREATE INDEX idx_health_insights_analyzed_at ON health_insights(analyzed_at DESC);
CREATE INDEX idx_health_insights_severity ON health_insights(severity);
