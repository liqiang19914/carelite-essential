
-- 情绪打卡记录表，支持一天多次打卡
CREATE TABLE mood_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  mood_level smallint NOT NULL CHECK (mood_level BETWEEN 1 AND 5),
  emotions text[] NOT NULL DEFAULT '{}',
  trigger text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  activity_type text NOT NULL DEFAULT '',
  activity_minutes integer NOT NULL DEFAULT 0,
  logged_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_mood_logs_user_id ON mood_logs(user_id);
CREATE INDEX idx_mood_logs_logged_at ON mood_logs(logged_at DESC);

COMMENT ON TABLE mood_logs IS '情绪打卡记录表，存储用户每次情绪打卡的心情评分、情绪标签、触发场景、笔记及正念活动，支持一天多次打卡';
COMMENT ON COLUMN mood_logs.mood_level IS '心情评分: 1=很差, 2=较差, 3=一般, 4=不错, 5=很好';
COMMENT ON COLUMN mood_logs.emotions IS '情绪标签数组，如 ["焦虑","疲惫","压力大"]';
COMMENT ON COLUMN mood_logs.trigger IS '触发场景: work=工作, family=家庭, health=健康, social=社交, finance=财务, sleep=睡眠, other=其他';
COMMENT ON COLUMN mood_logs.activity_type IS '正念活动类型: meditation=冥想, breathing=呼吸练习, relaxation=放松训练, 空字符串表示无活动';
COMMENT ON COLUMN mood_logs.activity_minutes IS '正念活动时长（分钟），0 表示无活动';

-- 情绪目标表
CREATE TABLE mood_goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  goal_type varchar(30) NOT NULL DEFAULT 'weekly_checkins',
  target_value integer NOT NULL DEFAULT 5,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_mood_goals_user_id ON mood_goals(user_id);
CREATE UNIQUE INDEX idx_mood_goals_user_active ON mood_goals(user_id) WHERE is_active = true;

COMMENT ON TABLE mood_goals IS '情绪目标表，存储用户的周情绪管理目标（每周打卡次数或每周正念时长），每个用户同时只能有一个激活的目标';
COMMENT ON COLUMN mood_goals.goal_type IS '目标类型: weekly_checkins=每周打卡天数, weekly_mindful_minutes=每周正念时长(分钟)';

-- RLS 策略
ALTER TABLE mood_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own mood logs"
  ON mood_logs FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own mood logs"
  ON mood_logs FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own mood logs"
  ON mood_logs FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "Users can update own mood logs"
  ON mood_logs FOR UPDATE USING (auth.uid() = user_id);

-- 管理师可查看客户的情绪记录（通过 client_relations）
CREATE POLICY "Managers can view client mood logs"
  ON mood_logs FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM client_relations cr
      WHERE cr.manager_id = auth.uid()
      AND cr.client_id = mood_logs.user_id
      AND cr.status = 'active'
    )
  );

ALTER TABLE mood_goals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own mood goals"
  ON mood_goals FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own mood goals"
  ON mood_goals FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own mood goals"
  ON mood_goals FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own mood goals"
  ON mood_goals FOR DELETE USING (auth.uid() = user_id);
