-- Sleep check-in tables (mirrors mood_logs / mood_goals pattern)

CREATE TABLE IF NOT EXISTS sleep_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  sleep_quality smallint NOT NULL CHECK (sleep_quality BETWEEN 1 AND 5),
  bedtime timestamptz NOT NULL,
  wake_time timestamptz NOT NULL,
  fall_asleep_minutes integer NOT NULL DEFAULT 15,
  wake_count integer NOT NULL DEFAULT 0,
  disturbances text[] NOT NULL DEFAULT '{}',
  notes text NOT NULL DEFAULT '',
  logged_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sleep_logs_user_id ON sleep_logs(user_id);
CREATE INDEX idx_sleep_logs_logged_at ON sleep_logs(logged_at DESC);
ALTER TABLE sleep_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage their own sleep logs"
  ON sleep_logs FOR ALL
  USING (auth.uid() = user_id);

CREATE TABLE IF NOT EXISTS sleep_goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  goal_type varchar(30) NOT NULL,
  target_value integer NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sleep_goals_user_id ON sleep_goals(user_id);
CREATE UNIQUE INDEX idx_sleep_goals_user_active ON sleep_goals(user_id) WHERE is_active = true;
ALTER TABLE sleep_goals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage their own sleep goals"
  ON sleep_goals FOR ALL
  USING (auth.uid() = user_id);