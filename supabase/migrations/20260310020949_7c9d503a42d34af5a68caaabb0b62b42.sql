-- OpenClaw connections: stores user's private/platform OpenClaw configurations
CREATE TABLE openclaw_connections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  mode text CHECK (mode IN ('private', 'platform')) DEFAULT 'private' NOT NULL,
  endpoint_url text,
  api_key text,
  status text CHECK (status IN ('connected', 'disconnected', 'error')) DEFAULT 'disconnected' NOT NULL,
  last_connected_at timestamptz,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- RLS: users can only manage their own connections
ALTER TABLE openclaw_connections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage own connections"
  ON openclaw_connections FOR ALL
  USING (auth.uid() = user_id);

-- OpenClaw messages: chat history for OpenClaw conversations
CREATE TABLE openclaw_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id uuid REFERENCES openclaw_connections(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role text CHECK (role IN ('user', 'assistant')) NOT NULL,
  content text NOT NULL,
  message_type text CHECK (message_type IN ('text', 'image', 'file')) DEFAULT 'text' NOT NULL,
  metadata jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now() NOT NULL
);

-- RLS: users can only manage their own messages
ALTER TABLE openclaw_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage own messages"
  ON openclaw_messages FOR ALL
  USING (auth.uid() = user_id);

-- Enable Realtime for Phase 2 push notifications
ALTER PUBLICATION supabase_realtime ADD TABLE openclaw_messages;