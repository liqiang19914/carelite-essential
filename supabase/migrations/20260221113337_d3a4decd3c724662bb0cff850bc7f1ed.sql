-- Add RLS policies to allow admin users to view ALL data across key tables
-- Admin role check: profiles.role = 'admin' for the current authenticated user

-- 1. health_records: allow admin to SELECT all
CREATE POLICY "admin_select_all_health_records"
  ON public.health_records
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

-- 2. conversations: allow admin to SELECT all
CREATE POLICY "admin_select_all_conversations"
  ON public.conversations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

-- 3. messages: allow admin to SELECT all
CREATE POLICY "admin_select_all_messages"
  ON public.messages
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

-- 4. vital_signs: allow admin to SELECT all
CREATE POLICY "admin_select_all_vital_signs"
  ON public.vital_signs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );