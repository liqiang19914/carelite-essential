-- ============================================================================
-- 问卷模块修复：附件真上传 / 客户发放 / 通知中心 / 保存可靠性防护
-- 变更概览：
--   1) 新建 notifications（用户级通知） + survey_assignments（管理师指派记录） 表
--   2) 为「被指派客户」放开 surveys / survey_questions 的 SELECT
--   3) 收紧 survey_responses INSERT 策略（禁止 anon 冒充；authenticated 必须 = auth.uid）
--   4) prevent_empty_survey_activation：BEFORE INSERT/UPDATE OF status，阻止零题目发布
--   5) handle_survey_response_insert：AFTER INSERT，原子维护 response_count 与指派完成态
-- ============================================================================

-- ---------- 1) notifications ----------
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type text NOT NULL,
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_created
  ON public.notifications (user_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON public.notifications (user_id, created_at DESC) WHERE read_at IS NULL;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own notifications"
  ON public.notifications FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- 写入与标已读均走 SECURITY DEFINER RPC，不开放直接 INSERT/UPDATE/DELETE 策略

-- 加入 Realtime publication（幂等）
DO $realtime$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  END IF;
END $realtime$;

-- ---------- 2) survey_assignments ----------
CREATE TABLE IF NOT EXISTS public.survey_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  survey_id uuid NOT NULL REFERENCES public.surveys(id) ON DELETE CASCADE,
  client_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  manager_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sent_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  response_id uuid REFERENCES public.survey_responses(id) ON DELETE SET NULL,
  CONSTRAINT survey_assignments_unique_pair UNIQUE (survey_id, client_user_id),
  CONSTRAINT survey_assignments_unique_response UNIQUE (response_id)
);

CREATE INDEX IF NOT EXISTS idx_survey_assignments_client_sent
  ON public.survey_assignments (client_user_id, sent_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_survey_assignments_manager_sent
  ON public.survey_assignments (manager_id, sent_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_survey_assignments_survey
  ON public.survey_assignments (survey_id);

ALTER TABLE public.survey_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Managers can view own survey assignments"
  ON public.survey_assignments FOR SELECT
  TO authenticated
  USING (auth.uid() = manager_id);

CREATE POLICY "Clients can view own survey assignments"
  ON public.survey_assignments FOR SELECT
  TO authenticated
  USING (auth.uid() = client_user_id);

-- ---------- 3) 被指派客户可看到问卷元信息 & 题目 ----------
CREATE POLICY "Assigned clients can view assigned surveys"
  ON public.surveys FOR SELECT
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.survey_assignments a
    WHERE a.survey_id = surveys.id
      AND a.client_user_id = auth.uid()
  ));

CREATE POLICY "Assigned clients can view assigned survey questions"
  ON public.survey_questions FOR SELECT
  TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.survey_assignments a
    WHERE a.survey_id = survey_questions.survey_id
      AND a.client_user_id = auth.uid()
  ));

-- ---------- 4) 收紧 survey_responses INSERT 策略 ----------
DROP POLICY IF EXISTS "Anyone can submit responses to active surveys" ON public.survey_responses;

CREATE POLICY "Anonymous can submit to active surveys"
  ON public.survey_responses FOR INSERT
  TO anon
  WITH CHECK (
    respondent_id IS NULL
    AND EXISTS (
      SELECT 1 FROM public.surveys
      WHERE surveys.id = survey_responses.survey_id
        AND surveys.status = 'active'
    )
  );

CREATE POLICY "Authenticated can submit to active surveys"
  ON public.survey_responses FOR INSERT
  TO authenticated
  WITH CHECK (
    respondent_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.surveys
      WHERE surveys.id = survey_responses.survey_id
        AND surveys.status = 'active'
    )
  );

-- ---------- 5) prevent_empty_survey_activation ----------
CREATE OR REPLACE FUNCTION public.prevent_empty_survey_activation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $prevent$
BEGIN
  IF NEW.status = 'active'::public.survey_status THEN
    IF (TG_OP = 'INSERT') OR (OLD.status IS DISTINCT FROM NEW.status) THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.survey_questions
        WHERE survey_id = NEW.id
      ) THEN
        RAISE EXCEPTION '问卷至少需要一道题目才能发布'
          USING ERRCODE = 'P0001',
                HINT   = 'ADD_QUESTION_BEFORE_PUBLISH';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$prevent$;

DROP TRIGGER IF EXISTS trg_prevent_empty_survey_activation ON public.surveys;
CREATE TRIGGER trg_prevent_empty_survey_activation
  BEFORE INSERT OR UPDATE OF status ON public.surveys
  FOR EACH ROW EXECUTE FUNCTION public.prevent_empty_survey_activation();

-- ---------- 6) handle_survey_response_insert ----------
CREATE OR REPLACE FUNCTION public.handle_survey_response_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $handle$
BEGIN
  UPDATE public.surveys
     SET response_count = response_count + 1,
         updated_at = now()
   WHERE id = NEW.survey_id;

  IF NEW.respondent_id IS NOT NULL THEN
    UPDATE public.survey_assignments
       SET completed_at = now(),
           response_id  = NEW.id
     WHERE survey_id = NEW.survey_id
       AND client_user_id = NEW.respondent_id
       AND completed_at IS NULL;
  END IF;

  RETURN NEW;
END;
$handle$;

DROP TRIGGER IF EXISTS trg_handle_survey_response_insert ON public.survey_responses;
CREATE TRIGGER trg_handle_survey_response_insert
  AFTER INSERT ON public.survey_responses
  FOR EACH ROW EXECUTE FUNCTION public.handle_survey_response_insert();