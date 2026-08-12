-- 在 Supabase SQL Editor 中执行整个文件
-- https://supabase.com/dashboard → 你的项目 → SQL Editor

-- 1. 用户扩展信息表
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE NOT NULL,
  role TEXT DEFAULT 'user' CHECK (role IN ('admin', 'user')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. 知识库表
CREATE TABLE IF NOT EXISTS knowledge_base (
  id TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category TEXT DEFAULT '',
  title TEXT NOT NULL,
  content TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. 对话历史表
CREATE TABLE IF NOT EXISTS chat_history (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. API 配置表
CREATE TABLE IF NOT EXISTS api_configs (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  model_id TEXT NOT NULL,
  endpoint TEXT DEFAULT '',
  api_key TEXT DEFAULT '',
  UNIQUE(user_id, model_id)
);

-- 5. 操作日志表
CREATE TABLE IF NOT EXISTS logs (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  username TEXT,
  action TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- RLS 策略
-- ============================================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE knowledge_base ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE logs ENABLE ROW LEVEL SECURITY;

-- 用户可读自己的 profile
DROP POLICY IF EXISTS "Users read own profile" ON profiles;
CREATE POLICY "Users read own profile" ON profiles
  FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "Admin read all profiles" ON profiles;
CREATE POLICY "Admin read all profiles" ON profiles
  FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "Admin insert profiles" ON profiles;
CREATE POLICY "Admin insert profiles" ON profiles
  FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') OR auth.uid() = id);

DROP POLICY IF EXISTS "Users manage own kb" ON knowledge_base;
CREATE POLICY "Users manage own kb" ON knowledge_base
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admin read all kb" ON knowledge_base;
CREATE POLICY "Admin read all kb" ON knowledge_base
  FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "Users manage own chat" ON chat_history;
CREATE POLICY "Users manage own chat" ON chat_history
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users manage own config" ON api_configs;
CREATE POLICY "Users manage own config" ON api_configs
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admin read logs" ON logs;
CREATE POLICY "Admin read logs" ON logs
  FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "Users insert logs" ON logs;
CREATE POLICY "Users insert logs" ON logs
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- ============================================================
-- 自动创建 profile 的触发器（用户注册时）
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, username, role)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'username', 'user');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- 创建 root 管理员账号
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO auth.users (id, instance_id, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at, role)
VALUES (
  gen_random_uuid(),
  '00000000-0000-0000-0000-000000000000',
  'root@ai.kb',
  crypt('admin123', gen_salt('bf')),
  now(),
  '{"username":"root"}',
  now(),
  now(),
  'authenticated'
) ON CONFLICT DO NOTHING;

UPDATE profiles SET role = 'admin' WHERE username = 'root';

-- ============================================================
-- RPC 函数：管理员创建用户（替代 Edge Function，无需 CLI 部署）
-- ============================================================

CREATE OR REPLACE FUNCTION create_app_user(username TEXT, password TEXT)
RETURNS JSON AS $$
DECLARE
  caller_role TEXT;
  new_user_id UUID;
BEGIN
  SELECT role INTO caller_role FROM profiles WHERE id = auth.uid();
  IF caller_role != 'admin' THEN
    RETURN jsonb_build_object('error', '需要管理员权限');
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users WHERE email = username || '@ai.kb') THEN
    RETURN jsonb_build_object('error', '用户已存在');
  END IF;

  INSERT INTO auth.users (id, instance_id, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at, role)
  VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', username || '@ai.kb', crypt(password, gen_salt('bf')), now(), jsonb_build_object('username', username), now(), now(), 'authenticated')
  RETURNING id INTO new_user_id;

  RETURN jsonb_build_object('ok', true, 'username', username, 'id', new_user_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 函数：用户修改自己的密码
-- ============================================================

CREATE OR REPLACE FUNCTION change_app_password(new_password TEXT)
RETURNS JSON AS $$
BEGIN
  UPDATE auth.users SET encrypted_password = crypt(new_password, gen_salt('bf')) WHERE id = auth.uid();
  RETURN jsonb_build_object('ok', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
