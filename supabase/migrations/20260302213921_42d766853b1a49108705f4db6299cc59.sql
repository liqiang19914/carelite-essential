-- Add invite_code column to managers table
ALTER TABLE managers ADD COLUMN IF NOT EXISTS invite_code VARCHAR(6) UNIQUE;

-- Function to generate unique 6-digit numeric invite code
CREATE OR REPLACE FUNCTION generate_manager_invite_code()
RETURNS VARCHAR(6) AS $$
DECLARE
  new_code VARCHAR(6);
  code_exists BOOLEAN;
BEGIN
  LOOP
    new_code := LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
    SELECT EXISTS(SELECT 1 FROM managers WHERE invite_code = new_code) INTO code_exists;
    EXIT WHEN NOT code_exists;
  END LOOP;
  RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-generate invite_code on INSERT if not provided
CREATE OR REPLACE FUNCTION auto_generate_manager_invite_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.invite_code IS NULL OR NEW.invite_code = '' THEN
    NEW.invite_code := generate_manager_invite_code();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS manager_invite_code_trigger ON managers;
CREATE TRIGGER manager_invite_code_trigger
BEFORE INSERT ON managers
FOR EACH ROW EXECUTE FUNCTION auto_generate_manager_invite_code();

-- Backfill existing managers that have no invite code
UPDATE managers SET invite_code = generate_manager_invite_code() WHERE invite_code IS NULL;

-- Make record_authorizations.expires_at nullable for permanent authorization
ALTER TABLE record_authorizations ALTER COLUMN expires_at DROP NOT NULL;