
-- Enable RLS on exercise_logs
ALTER TABLE exercise_logs ENABLE ROW LEVEL SECURITY;

-- Users can view their own exercise logs
CREATE POLICY "Users can view own exercise logs"
ON exercise_logs FOR SELECT
USING (auth.uid() = user_id);

-- Users can insert their own exercise logs
CREATE POLICY "Users can insert own exercise logs"
ON exercise_logs FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Users can delete their own exercise logs
CREATE POLICY "Users can delete own exercise logs"
ON exercise_logs FOR DELETE
USING (auth.uid() = user_id);

-- Users can update their own exercise logs
CREATE POLICY "Users can update own exercise logs"
ON exercise_logs FOR UPDATE
USING (auth.uid() = user_id);

-- Managers can view their clients' exercise logs
CREATE POLICY "Managers can view client exercise logs"
ON exercise_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM client_relations cr
    WHERE cr.client_id = exercise_logs.user_id
      AND cr.manager_id = auth.uid()
      AND cr.status = 'active'
  )
);

-- Enable RLS on exercise_goals
ALTER TABLE exercise_goals ENABLE ROW LEVEL SECURITY;

-- Users can view their own goals
CREATE POLICY "Users can view own exercise goals"
ON exercise_goals FOR SELECT
USING (auth.uid() = user_id);

-- Users can insert their own goals
CREATE POLICY "Users can insert own exercise goals"
ON exercise_goals FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Users can update their own goals
CREATE POLICY "Users can update own exercise goals"
ON exercise_goals FOR UPDATE
USING (auth.uid() = user_id);

-- Users can delete their own goals
CREATE POLICY "Users can delete own exercise goals"
ON exercise_goals FOR DELETE
USING (auth.uid() = user_id);
