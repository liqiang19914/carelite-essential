-- 固定时间提醒触发记录：防止同一提醒在同一天被 cron 重复触发发送
-- 每条提醒每天最多触发一次（peer_id + peer_type + reminder_id + fired_date 唯一约束）
CREATE TABLE IF NOT EXISTS public.wecom_super_peer_reminder_fires (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL,
  peer_id text NOT NULL,
  peer_type text NOT NULL,           -- contact | room
  reminder_id text NOT NULL,
  fired_date date NOT NULL,          -- 北京日期
  task_id uuid,                      -- 关联的发送任务
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (peer_id, peer_type, reminder_id, fired_date)
);

CREATE INDEX IF NOT EXISTS idx_peer_reminder_fires_root
  ON public.wecom_super_peer_reminder_fires (root_manager_id, fired_date);
