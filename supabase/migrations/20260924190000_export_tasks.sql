-- 后台导出任务表：替代同步 RPC 导出，避免大数据量前端卡顿/超时。
-- 流程：前端 INSERT 一条 pending 任务 → invoke('export-data-async') → Edge Function 查 DB 生成 CSV
-- → 上传 OSS → 更新 status=done+file_url → 前端轮询 status 后下载。
-- 迁移幂等：CREATE TABLE IF NOT EXISTS + DO 块 guarded。

CREATE TABLE IF NOT EXISTS public.export_tasks (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL,                       -- 发起人（企业根 manager id）
  type            text NOT NULL CHECK (type IN ('clients','surveys','health')),
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','processing','done','failed')),
  file_url        text,                                -- OSS 公开下载 URL
  file_name       text,                                -- 下载时展示的文件名（客户数据_YYYYMMDD.csv）
  row_count       integer NOT NULL DEFAULT 0,
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz
);

CREATE INDEX IF NOT EXISTS export_tasks_root_created_idx
  ON public.export_tasks (root_manager_id, created_at DESC);

ALTER TABLE public.export_tasks ENABLE ROW LEVEL SECURITY;

-- 用户只能读写自己发起的导出任务
DROP POLICY IF EXISTS export_tasks_select_own ON public.export_tasks;
CREATE POLICY export_tasks_select_own ON public.export_tasks
  FOR SELECT USING (root_manager_id = auth.uid());

DROP POLICY IF EXISTS export_tasks_insert_own ON public.export_tasks;
CREATE POLICY export_tasks_insert_own ON public.export_tasks
  FOR INSERT WITH CHECK (root_manager_id = auth.uid());

DROP POLICY IF EXISTS export_tasks_update_own ON public.export_tasks;
CREATE POLICY export_tasks_update_own ON public.export_tasks
  FOR UPDATE USING (root_manager_id = auth.uid());

-- service role 绕过 RLS 全部读写（Edge Function 用）
GRANT SELECT, INSERT, UPDATE ON public.export_tasks TO authenticated;

COMMENT ON TABLE public.export_tasks IS
  '后台导出任务记录。前端创建 pending 任务后调用 export-data-async Edge Function 生成 CSV 并上传 OSS，完成后置 status=done + file_url。';
