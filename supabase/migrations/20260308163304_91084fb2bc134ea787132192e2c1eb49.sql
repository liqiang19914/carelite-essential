
-- 运动打卡记录表
CREATE TABLE exercise_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  record_id uuid REFERENCES health_records(id) ON DELETE SET NULL,
  exercise_type varchar(30) NOT NULL,
  duration_minutes integer NOT NULL CHECK (duration_minutes > 0),
  distance_km numeric(6,2),
  intensity varchar(10) NOT NULL DEFAULT 'medium' CHECK (intensity IN ('low', 'medium', 'high')),
  calories integer,
  notes text DEFAULT '',
  exercised_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_exercise_logs_user_id ON exercise_logs(user_id);
CREATE INDEX idx_exercise_logs_exercised_at ON exercise_logs(exercised_at DESC);

COMMENT ON TABLE exercise_logs IS '运动打卡记录表，存储用户每次运动打卡的详细信息，支持一天多次打卡';
COMMENT ON COLUMN exercise_logs.exercise_type IS '运动类型: walking=步行, running=跑步, cycling=骑行, swimming=游泳, yoga=瑜伽, strength=力量训练, ball_sports=球类运动, other=其他';
COMMENT ON COLUMN exercise_logs.intensity IS '运动强度: low=低, medium=中, high=高';

-- 运动目标表
CREATE TABLE exercise_goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  goal_type varchar(20) NOT NULL CHECK (goal_type IN ('weekly_count', 'weekly_minutes')),
  target_value integer NOT NULL CHECK (target_value > 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_exercise_goals_user_active ON exercise_goals(user_id) WHERE is_active = true;
CREATE INDEX idx_exercise_goals_user_id ON exercise_goals(user_id);

COMMENT ON TABLE exercise_goals IS '运动目标表，存储用户的周运动目标（每周次数或每周时长），每个用户同时只能有一个激活的目标';
COMMENT ON COLUMN exercise_goals.goal_type IS '目标类型: weekly_count=每周运动次数, weekly_minutes=每周运动时长(分钟)';
