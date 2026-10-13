-- 创建AI智能体表
CREATE TABLE ai_agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL,
  slug VARCHAR(50) NOT NULL UNIQUE,
  icon VARCHAR(10),
  description TEXT,
  welcome_message TEXT,
  system_prompt TEXT,
  is_enabled BOOLEAN DEFAULT TRUE,
  display_order INTEGER DEFAULT 0,
  conversation_count INTEGER DEFAULT 0,
  user_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建对话表
CREATE TABLE conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_id UUID REFERENCES ai_agents(id) ON DELETE SET NULL,
  title VARCHAR(200),
  status VARCHAR(20) DEFAULT 'active',
  message_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建消息表
CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role VARCHAR(20) NOT NULL,
  content TEXT NOT NULL,
  is_flagged BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建索引
CREATE INDEX idx_conversations_user_id ON conversations(user_id);
CREATE INDEX idx_conversations_agent_id ON conversations(agent_id);
CREATE INDEX idx_conversations_updated_at ON conversations(updated_at DESC);
CREATE INDEX idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX idx_messages_created_at ON messages(created_at);

-- 启用RLS
ALTER TABLE ai_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

-- AI智能体表策略（所有人可读）
CREATE POLICY "Anyone can view enabled agents"
  ON ai_agents FOR SELECT
  USING (is_enabled = true);

CREATE POLICY "Admins can manage agents"
  ON ai_agents FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
    )
  );

-- 对话表策略
CREATE POLICY "Users can view own conversations"
  ON conversations FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create own conversations"
  ON conversations FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own conversations"
  ON conversations FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own conversations"
  ON conversations FOR DELETE
  USING (auth.uid() = user_id);

-- 消息表策略
CREATE POLICY "Users can view own messages"
  ON messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM conversations
      WHERE conversations.id = messages.conversation_id
      AND conversations.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can create own messages"
  ON messages FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM conversations
      WHERE conversations.id = conversation_id
      AND conversations.user_id = auth.uid()
    )
  );

-- 插入默认智能体数据
INSERT INTO ai_agents (name, slug, icon, description, welcome_message, system_prompt, is_enabled, display_order) VALUES
('全科健康助手', 'general', '🩺', '综合健康咨询，提供全面的健康建议', '您好！我是全科健康助手，有什么健康问题可以帮您？', '你是一个专业的全科健康助手，提供全面的健康咨询服务。回答要专业、准确、有温度。每次回复末尾都要提醒用户：以上建议仅供参考，如有不适请及时就医。', true, 1),
('皮肤科助手', 'dermatology', '🧴', '皮肤问题咨询，护肤建议', '您好！我是皮肤科健康助手，皮肤问题可以问我哦～', '你是一个专业的皮肤科健康助手，擅长解答皮肤相关问题，包括常见皮肤病、护肤建议、皮肤保养等。回答要专业、准确。每次回复末尾都要提醒用户：以上建议仅供参考，皮肤问题建议到正规医院皮肤科就诊。', true, 2),
('肠胃科助手', 'gastro', '🫄', '消化系统问题咨询，饮食建议', '您好！我是肠胃科健康助手，肠胃不舒服可以问我～', '你是一个专业的肠胃科健康助手，擅长解答消化系统相关问题，包括胃病、肠道问题、饮食建议等。回答要专业、准确。每次回复末尾都要提醒用户：以上建议仅供参考，肠胃不适请及时就医。', true, 3),
('骨科助手', 'ortho', '🦴', '骨骼关节问题咨询，运动建议', '您好！我是骨科健康助手，骨骼关节问题可以问我～', '你是一个专业的骨科健康助手，擅长解答骨骼、关节、肌肉相关问题，包括颈椎病、腰椎间盘突出、关节炎、运动损伤等。回答要专业、准确。每次回复末尾都要提醒用户：以上建议仅供参考，骨科问题请到正规医院就诊。', true, 4),
('心内科助手', 'cardio', '❤️', '心血管问题咨询，生活方式建议', '您好！我是心内科健康助手，心血管问题可以问我～', '你是一个专业的心内科健康助手，擅长解答心血管相关问题，包括高血压、心脏病、血脂异常等。回答要专业、准确。每次回复末尾都要提醒用户：以上建议仅供参考，心血管问题请及时就医检查。', true, 5),
('神经科助手', 'neuro', '🧠', '神经系统问题咨询，睡眠建议', '您好！我是神经科健康助手，头疼头晕失眠都可以问我～', '你是一个专业的神经科健康助手，擅长解答神经系统相关问题，包括头痛、头晕、失眠、焦虑等。回答要专业、准确。每次回复末尾都要提醒用户：以上建议仅供参考，神经系统问题请到正规医院神经内科就诊。', true, 6);