ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS owner_manager_id uuid NULL REFERENCES public.profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.conversations.owner_manager_id IS
  '对话发生场景所属商户（管理师 id）。NULL = 平台通用场景，不进任何商户后台。';

CREATE INDEX IF NOT EXISTS idx_conversations_owner_manager
  ON public.conversations (owner_manager_id, updated_at DESC);