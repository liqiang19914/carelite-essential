-- Fix: Allow users to bind managers via invite code
-- Root cause: RLS policies only allow manager_id = auth.uid(), blocking user-side operations

-- 1. Allow all authenticated users to query managers table (needed for invite_code lookup)
CREATE POLICY "Authenticated users can find managers by invite code"
  ON managers FOR SELECT
  USING (auth.role() = 'authenticated');

-- 2. Allow users to view their own client_relations bindings
CREATE POLICY "Users can view own bindings"
  ON client_relations FOR SELECT
  USING (auth.uid() = client_id);

-- 3. Allow users to create their own binding record
CREATE POLICY "Users can create own binding"
  ON client_relations FOR INSERT
  WITH CHECK (auth.uid() = client_id);

-- 4. Allow users to update their own binding status (for unbinding)
CREATE POLICY "Users can update own binding"
  ON client_relations FOR UPDATE
  USING (auth.uid() = client_id);

-- 5. Allow users to view authorizations of their own health records
CREATE POLICY "Users can view own record authorizations"
  ON record_authorizations FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM health_records
    WHERE health_records.id = record_id
    AND health_records.user_id = auth.uid()
  ));