-- 企微超级助手：好友/群资料卡 扩展
-- 1) contacts / rooms 加 reminders jsonb（固定时间提醒数组）
-- 2) EF 层扩展 peer.note.get：返回 reminders + 关联档案信息（mapping→profiles.nickname）

ALTER TABLE public.wecom_super_contacts
  ADD COLUMN IF NOT EXISTS reminders jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.wecom_super_rooms
  ADD COLUMN IF NOT EXISTS reminders jsonb NOT NULL DEFAULT '[]'::jsonb;

-- reminders 结构（数组）：
-- [{
--   "id": "uuid-string",
--   "time": "08:00",
--   "content": "提醒吃降压药",
--   "weekdays": [1,2,3,4,5,6,7],
--   "enabled": true
-- }]
-- weekdays: 1=周日 … 7=周六（与 JS new Date().getDay() 对齐）
-- 触发时机：管理端浏览器 Notification API 本地弹出（不自动发微信消息，避免封号）。
