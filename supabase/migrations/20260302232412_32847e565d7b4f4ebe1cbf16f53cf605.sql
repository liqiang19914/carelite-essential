-- 1. Create SECURITY DEFINER function to check health record ownership
-- This bypasses RLS, breaking the circular dependency between health_records and record_authorizations
CREATE OR REPLACE FUNCTION owns_health_record(p_user_id UUID, p_record_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM health_records
    WHERE id = p_record_id AND user_id = p_user_id
  );
$$;

GRANT EXECUTE ON FUNCTION owns_health_record(UUID, UUID) TO anon, authenticated;

-- 2. Drop the problematic policy that causes infinite recursion
DROP POLICY IF EXISTS "Users can view own record authorizations" ON record_authorizations;

-- 3. Recreate the policy using the SECURITY DEFINER function (no RLS cycle)
CREATE POLICY "Users can view own record authorizations"
  ON record_authorizations FOR SELECT
  USING (owns_health_record(auth.uid(), record_id));

-- 4. Allow users to view their bound manager's profile
CREATE POLICY "Users can view bound manager profile"
  ON profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM client_relations
      WHERE client_relations.manager_id = profiles.id
      AND client_relations.client_id = auth.uid()
      AND client_relations.status = 'active'
    )
  );