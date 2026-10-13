-- 创建问卷状态枚举
CREATE TYPE survey_status AS ENUM ('draft', 'active', 'closed');

-- 创建问卷表
CREATE TABLE surveys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title VARCHAR(200) NOT NULL,
  description TEXT,
  status survey_status DEFAULT 'draft',
  is_template BOOLEAN DEFAULT FALSE,
  share_code VARCHAR(20) UNIQUE,
  response_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建问卷题目表
CREATE TABLE survey_questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  survey_id UUID NOT NULL REFERENCES surveys(id) ON DELETE CASCADE,
  question_type VARCHAR(20) NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  options JSONB,
  is_required BOOLEAN DEFAULT TRUE,
  display_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建问卷回答表
CREATE TABLE survey_responses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  survey_id UUID NOT NULL REFERENCES surveys(id) ON DELETE CASCADE,
  respondent_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  respondent_name VARCHAR(100),
  respondent_phone VARCHAR(20),
  answers JSONB NOT NULL,
  submitted_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建索引
CREATE INDEX idx_surveys_manager_id ON surveys(manager_id);
CREATE INDEX idx_surveys_share_code ON surveys(share_code);
CREATE INDEX idx_survey_questions_survey_id ON survey_questions(survey_id);
CREATE INDEX idx_survey_responses_survey_id ON survey_responses(survey_id);

-- 启用 RLS
ALTER TABLE surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE survey_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE survey_responses ENABLE ROW LEVEL SECURITY;

-- surveys 表策略
CREATE POLICY "Managers can view own surveys"
  ON surveys FOR SELECT
  USING (auth.uid() = manager_id);

CREATE POLICY "Managers can manage own surveys"
  ON surveys FOR ALL
  USING (auth.uid() = manager_id);

CREATE POLICY "Anyone can view active surveys by share code"
  ON surveys FOR SELECT
  USING (status = 'active' AND share_code IS NOT NULL);

-- survey_questions 表策略
CREATE POLICY "Managers can view own survey questions"
  ON survey_questions FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM surveys
    WHERE surveys.id = survey_questions.survey_id
    AND surveys.manager_id = auth.uid()
  ));

CREATE POLICY "Managers can manage own survey questions"
  ON survey_questions FOR ALL
  USING (EXISTS (
    SELECT 1 FROM surveys
    WHERE surveys.id = survey_id
    AND surveys.manager_id = auth.uid()
  ));

CREATE POLICY "Anyone can view questions of active surveys"
  ON survey_questions FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM surveys
    WHERE surveys.id = survey_questions.survey_id
    AND surveys.status = 'active'
  ));

-- survey_responses 表策略
CREATE POLICY "Managers can view responses to own surveys"
  ON survey_responses FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM surveys
    WHERE surveys.id = survey_responses.survey_id
    AND surveys.manager_id = auth.uid()
  ));

CREATE POLICY "Anyone can submit responses to active surveys"
  ON survey_responses FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM surveys
    WHERE surveys.id = survey_id
    AND surveys.status = 'active'
  ));

-- 生成分享码的函数
CREATE OR REPLACE FUNCTION generate_share_code()
RETURNS TEXT AS $$
DECLARE
  chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  result TEXT := '';
  i INTEGER;
BEGIN
  FOR i IN 1..8 LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::integer, 1);
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- 触发器：发布问卷时自动生成分享码
CREATE OR REPLACE FUNCTION auto_generate_share_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'active' AND NEW.share_code IS NULL THEN
    NEW.share_code := generate_share_code();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER survey_auto_share_code
  BEFORE INSERT OR UPDATE ON surveys
  FOR EACH ROW EXECUTE FUNCTION auto_generate_share_code();