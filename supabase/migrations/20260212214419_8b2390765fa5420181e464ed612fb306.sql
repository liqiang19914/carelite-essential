-- 创建用户角色枚举
CREATE TYPE user_role AS ENUM ('user', 'manager', 'admin');

-- 创建用户资料表（扩展 auth.users）
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone VARCHAR(20),
  nickname VARCHAR(100),
  avatar_url TEXT,
  role user_role DEFAULT 'user',
  is_verified BOOLEAN DEFAULT FALSE,
  real_name VARCHAR(100),
  id_card VARCHAR(20),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建健康档案表（支持多成员）
CREATE TABLE health_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  relationship VARCHAR(50) NOT NULL DEFAULT '本人',
  gender VARCHAR(10),
  birth_date DATE,
  height DECIMAL(5,2),
  weight DECIMAL(5,2),
  blood_type VARCHAR(10),
  medical_history TEXT,
  allergy_history TEXT,
  surgery_history TEXT,
  medication_history TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建体征数据表
CREATE TABLE vital_signs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id UUID NOT NULL REFERENCES health_records(id) ON DELETE CASCADE,
  heart_rate INTEGER,
  systolic_pressure INTEGER,
  diastolic_pressure INTEGER,
  blood_sugar DECIMAL(4,2),
  temperature DECIMAL(4,2),
  weight DECIMAL(5,2),
  recorded_at TIMESTAMPTZ DEFAULT NOW(),
  notes TEXT
);

-- 创建索引
CREATE INDEX idx_health_records_user_id ON health_records(user_id);
CREATE INDEX idx_vital_signs_record_id ON vital_signs(record_id);
CREATE INDEX idx_vital_signs_recorded_at ON vital_signs(recorded_at DESC);

-- 启用 RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE vital_signs ENABLE ROW LEVEL SECURITY;

-- profiles 表 RLS 策略
CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

-- health_records 表 RLS 策略
CREATE POLICY "Users can view own health records"
  ON health_records FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own health records"
  ON health_records FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own health records"
  ON health_records FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own health records"
  ON health_records FOR DELETE
  USING (auth.uid() = user_id);

-- vital_signs 表 RLS 策略
CREATE POLICY "Users can view own vital signs"
  ON vital_signs FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM health_records 
    WHERE health_records.id = vital_signs.record_id 
    AND health_records.user_id = auth.uid()
  ));

CREATE POLICY "Users can insert own vital signs"
  ON vital_signs FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM health_records 
    WHERE health_records.id = record_id 
    AND health_records.user_id = auth.uid()
  ));

CREATE POLICY "Users can update own vital signs"
  ON vital_signs FOR UPDATE
  USING (EXISTS (
    SELECT 1 FROM health_records 
    WHERE health_records.id = vital_signs.record_id 
    AND health_records.user_id = auth.uid()
  ));

CREATE POLICY "Users can delete own vital signs"
  ON vital_signs FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM health_records 
    WHERE health_records.id = vital_signs.record_id 
    AND health_records.user_id = auth.uid()
  ));

-- 创建触发器函数（自动创建用户资料）
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, phone, nickname)
  VALUES (
    NEW.id,
    NEW.phone,
    COALESCE(NEW.raw_user_meta_data->>'nickname', '用户' || SUBSTR(NEW.phone::text, -4))
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 创建触发器
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();