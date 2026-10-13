-- 创建管理员扩展表（小B商户信息）
CREATE TABLE managers (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  business_name VARCHAR(200),
  business_license VARCHAR(100),
  certification_status VARCHAR(20) DEFAULT 'pending',
  membership_level VARCHAR(20) DEFAULT 'free',
  membership_expires_at TIMESTAMPTZ,
  client_count INTEGER DEFAULT 0,
  survey_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建客户关系表（管理员-客户）
CREATE TABLE client_relations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  client_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  last_contact_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(manager_id, client_id)
);

-- 创建客户标签表
CREATE TABLE client_tags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name VARCHAR(50) NOT NULL,
  color VARCHAR(20) DEFAULT 'blue',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建客户-标签关联表
CREATE TABLE client_tag_relations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_relation_id UUID NOT NULL REFERENCES client_relations(id) ON DELETE CASCADE,
  tag_id UUID NOT NULL REFERENCES client_tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(client_relation_id, tag_id)
);

-- 创建跟进记录表
CREATE TABLE follow_up_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_relation_id UUID NOT NULL REFERENCES client_relations(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  follow_up_type VARCHAR(50),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建档案授权表
CREATE TABLE record_authorizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id UUID NOT NULL REFERENCES health_records(id) ON DELETE CASCADE,
  manager_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT TRUE,
  UNIQUE(record_id, manager_id)
);

-- 创建索引
CREATE INDEX idx_client_relations_manager_id ON client_relations(manager_id);
CREATE INDEX idx_client_relations_client_id ON client_relations(client_id);
CREATE INDEX idx_client_tags_manager_id ON client_tags(manager_id);
CREATE INDEX idx_follow_up_records_client_relation_id ON follow_up_records(client_relation_id);
CREATE INDEX idx_record_authorizations_manager_id ON record_authorizations(manager_id);

-- 启用 RLS
ALTER TABLE managers ENABLE ROW LEVEL SECURITY;
ALTER TABLE client_relations ENABLE ROW LEVEL SECURITY;
ALTER TABLE client_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE client_tag_relations ENABLE ROW LEVEL SECURITY;
ALTER TABLE follow_up_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE record_authorizations ENABLE ROW LEVEL SECURITY;

-- managers 表策略
CREATE POLICY "Users can view own manager profile"
  ON managers FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own manager profile"
  ON managers FOR UPDATE
  USING (auth.uid() = id);

CREATE POLICY "Users can insert own manager profile"
  ON managers FOR INSERT
  WITH CHECK (auth.uid() = id);

-- client_relations 表策略
CREATE POLICY "Managers can view own client relations"
  ON client_relations FOR SELECT
  USING (auth.uid() = manager_id);

CREATE POLICY "Managers can manage own client relations"
  ON client_relations FOR ALL
  USING (auth.uid() = manager_id);

-- client_tags 表策略
CREATE POLICY "Managers can view own tags"
  ON client_tags FOR SELECT
  USING (auth.uid() = manager_id);

CREATE POLICY "Managers can manage own tags"
  ON client_tags FOR ALL
  USING (auth.uid() = manager_id);

-- client_tag_relations 表策略
CREATE POLICY "Managers can view own tag relations"
  ON client_tag_relations FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM client_relations
    WHERE client_relations.id = client_tag_relations.client_relation_id
    AND client_relations.manager_id = auth.uid()
  ));

CREATE POLICY "Managers can manage own tag relations"
  ON client_tag_relations FOR ALL
  USING (EXISTS (
    SELECT 1 FROM client_relations
    WHERE client_relations.id = client_relation_id
    AND client_relations.manager_id = auth.uid()
  ));

-- follow_up_records 表策略
CREATE POLICY "Managers can view own follow up records"
  ON follow_up_records FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM client_relations
    WHERE client_relations.id = follow_up_records.client_relation_id
    AND client_relations.manager_id = auth.uid()
  ));

CREATE POLICY "Managers can manage own follow up records"
  ON follow_up_records FOR ALL
  USING (EXISTS (
    SELECT 1 FROM client_relations
    WHERE client_relations.id = client_relation_id
    AND client_relations.manager_id = auth.uid()
  ));

-- record_authorizations 表策略
CREATE POLICY "Managers can view authorized records"
  ON record_authorizations FOR SELECT
  USING (auth.uid() = manager_id AND is_active = true);

CREATE POLICY "Users can grant authorization"
  ON record_authorizations FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM health_records
    WHERE health_records.id = record_id
    AND health_records.user_id = auth.uid()
  ));

CREATE POLICY "Users can revoke authorization"
  ON record_authorizations FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM health_records
    WHERE health_records.id = record_id
    AND health_records.user_id = auth.uid()
  ));

-- 添加管理员查看已授权健康档案的策略
CREATE POLICY "Managers can view authorized health records"
  ON health_records FOR SELECT
  USING (
    auth.uid() = user_id 
    OR EXISTS (
      SELECT 1 FROM record_authorizations
      WHERE record_authorizations.record_id = health_records.id
      AND record_authorizations.manager_id = auth.uid()
      AND record_authorizations.is_active = true
    )
  );