-- ====================================================================
-- 商城 Phase 1.A：products / product_skus / product_image_generations /
-- product_share_grants / avatar_profiles_cache + can_view_product 帮助函数
-- + RLS 策略 + 默认 SKU & updated_at 触发器
-- ====================================================================

-- 1. products 主表
CREATE TABLE products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type TEXT NOT NULL CHECK (source_type IN ('platform','manager')),
  owner_manager_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  title VARCHAR(200) NOT NULL,
  subtitle VARCHAR(300) NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  cover_image_url TEXT NOT NULL DEFAULT '',
  gallery_images JSONB NOT NULL DEFAULT '[]'::jsonb,
  category VARCHAR(50) NOT NULL DEFAULT 'general',
  tags TEXT[] NOT NULL DEFAULT '{}'::text[],
  status VARCHAR(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
  is_featured BOOLEAN NOT NULL DEFAULT false,
  sort_weight INTEGER NOT NULL DEFAULT 0,
  sales_count INTEGER NOT NULL DEFAULT 0,
  view_count INTEGER NOT NULL DEFAULT 0,
  created_by UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT products_source_owner_check CHECK (
    (source_type = 'platform' AND owner_manager_id IS NULL)
    OR (source_type = 'manager' AND owner_manager_id IS NOT NULL)
  )
);

COMMENT ON TABLE products IS '商城商品主表：平台严选 + 管理师私域双层货架';
COMMENT ON COLUMN products.source_type IS 'platform=平台严选（所有 C 端可见）；manager=管理师私域（需 product_share_grants 显式授权）';
COMMENT ON COLUMN products.is_featured IS '推荐位标记，仅 admin 可对 platform 商品设为 true';

CREATE INDEX idx_products_source_status_created ON products (source_type, status, created_at DESC);
CREATE INDEX idx_products_owner_status ON products (owner_manager_id, status) WHERE source_type = 'manager';
CREATE INDEX idx_products_status_featured ON products (status, is_featured DESC, sort_weight DESC) WHERE status = 'active';

-- 2. product_skus（V1 单 SKU，独立表预留扩展）
CREATE TABLE product_skus (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  sku_code VARCHAR(50) NOT NULL DEFAULT 'DEFAULT',
  price_cents INTEGER NOT NULL DEFAULT 0 CHECK (price_cents >= 0),
  original_price_cents INTEGER CHECK (original_price_cents IS NULL OR original_price_cents >= 0),
  stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_default BOOLEAN NOT NULL DEFAULT true,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_id, sku_code)
);

CREATE INDEX idx_product_skus_product ON product_skus (product_id);

-- 3. product_image_generations（AI 美化任务）
CREATE TABLE product_image_generations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID REFERENCES products(id) ON DELETE SET NULL,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  source_image_url TEXT NOT NULL,
  prompt TEXT NOT NULL DEFAULT '',
  preset_key VARCHAR(50) NOT NULL DEFAULT 'clean_white',
  candidate_urls JSONB NOT NULL DEFAULT '[]'::jsonb,
  selected_url TEXT NOT NULL DEFAULT '',
  count INTEGER NOT NULL DEFAULT 4 CHECK (count >= 1 AND count <= 8),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','generating','ready','failed')),
  model_used TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

COMMENT ON TABLE product_image_generations IS '商品图 AI 美化任务记录，多候选 + 用户选定';

CREATE INDEX idx_product_image_gens_user ON product_image_generations (user_id, created_at DESC);
CREATE INDEX idx_product_image_gens_product ON product_image_generations (product_id, created_at DESC);

-- 4. product_share_grants（管理师私域商品的显式分享）
CREATE TABLE product_share_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  manager_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  client_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  audience TEXT NOT NULL DEFAULT 'specific' CHECK (audience IN ('specific','all_clients','tag')),
  tag_id UUID REFERENCES client_tags(id) ON DELETE CASCADE,
  share_token VARCHAR(40) UNIQUE,
  note TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
);

COMMENT ON TABLE product_share_grants IS '管理师私域商品的显式分享授权（specific 单客户 / all_clients 全部客户 / tag 标签下客户）';

CREATE INDEX idx_product_share_grants_product ON product_share_grants (product_id);
CREATE INDEX idx_product_share_grants_client_manager ON product_share_grants (client_id, manager_id) WHERE audience = 'specific';
CREATE INDEX idx_product_share_grants_manager ON product_share_grants (manager_id, created_at DESC);

-- 5. avatar_profiles_cache（M2 数字人元数据缓存占位）
CREATE TABLE avatar_profiles_cache (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_avatar_id VARCHAR(100) NOT NULL UNIQUE,
  display_name VARCHAR(100) NOT NULL DEFAULT '',
  avatar_thumb_url TEXT NOT NULL DEFAULT '',
  voice_id VARCHAR(100) NOT NULL DEFAULT '',
  voice_name VARCHAR(100) NOT NULL DEFAULT '',
  voice_sample_url TEXT NOT NULL DEFAULT '',
  capability_tags JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_available BOOLEAN NOT NULL DEFAULT true,
  last_synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE avatar_profiles_cache IS 'M2 占位：从数字人项目拉取的形象/音色清单缓存';

-- ============ Helper Function: can_view_product ============

CREATE OR REPLACE FUNCTION public.can_view_product(
  p_product_id UUID,
  p_user_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_source TEXT;
  v_owner UUID;
  v_status TEXT;
BEGIN
  IF p_product_id IS NULL OR p_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT source_type, owner_manager_id, status
    INTO v_source, v_owner, v_status
    FROM products
    WHERE id = p_product_id;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- 1. admin 全可见
  IF EXISTS (
    SELECT 1 FROM profiles WHERE id = p_user_id AND role = 'admin'
  ) THEN
    RETURN TRUE;
  END IF;

  -- 2. 平台严选 + active：所有用户可见
  IF v_source = 'platform' AND v_status = 'active' THEN
    RETURN TRUE;
  END IF;

  -- 3. 平台严选 + 非 active：仅 admin（上面已拦截）
  IF v_source = 'platform' THEN
    RETURN FALSE;
  END IF;

  -- 4. 管理师私域：作者本人可见所有状态
  IF v_source = 'manager' AND v_owner = p_user_id THEN
    RETURN TRUE;
  END IF;

  -- 5. 管理师私域 active：通过 share_grants 显式授权才可见
  IF v_source = 'manager' AND v_status = 'active' THEN
    -- 5.1 specific 直接授权给该用户
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      WHERE g.product_id = p_product_id
        AND g.audience = 'specific'
        AND g.client_id = p_user_id
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 5.2 all_clients：用户是该管理师的活跃客户
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      INNER JOIN client_relations cr
        ON cr.manager_id = g.manager_id
       AND cr.client_id = p_user_id
       AND cr.status = 'active'
      WHERE g.product_id = p_product_id
        AND g.audience = 'all_clients'
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 5.3 tag：用户在该管理师的标签下
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      INNER JOIN client_relations cr
        ON cr.manager_id = g.manager_id
       AND cr.client_id = p_user_id
       AND cr.status = 'active'
      INNER JOIN client_tag_relations ctr
        ON ctr.client_relation_id = cr.id
       AND ctr.tag_id = g.tag_id
      WHERE g.product_id = p_product_id
        AND g.audience = 'tag'
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;
  END IF;

  RETURN FALSE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.can_view_product(UUID, UUID) TO anon, authenticated;

-- ============ 通用 updated_at trigger function ============

CREATE OR REPLACE FUNCTION public.shop_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ============ products 默认 SKU 自动创建 ============

CREATE OR REPLACE FUNCTION public.auto_create_default_sku()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO product_skus (product_id, sku_code, price_cents, stock, is_default, is_active)
  VALUES (NEW.id, 'DEFAULT', 0, 0, true, true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER products_after_insert_create_sku
AFTER INSERT ON products
FOR EACH ROW
EXECUTE FUNCTION public.auto_create_default_sku();

CREATE TRIGGER products_set_updated_at_trigger
BEFORE UPDATE ON products
FOR EACH ROW
EXECUTE FUNCTION public.shop_set_updated_at();

CREATE TRIGGER product_skus_set_updated_at_trigger
BEFORE UPDATE ON product_skus
FOR EACH ROW
EXECUTE FUNCTION public.shop_set_updated_at();

-- ============ RLS Policies ============

-- ---- products ----
ALTER TABLE products ENABLE ROW LEVEL SECURITY;

CREATE POLICY "products_select_via_visibility"
  ON products FOR SELECT
  USING (public.can_view_product(id, auth.uid()));

CREATE POLICY "products_admin_insert_platform"
  ON products FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    AND source_type = 'platform'
    AND owner_manager_id IS NULL
  );

CREATE POLICY "products_manager_insert_own"
  ON products FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'manager')
    AND source_type = 'manager'
    AND owner_manager_id = auth.uid()
    AND created_by = auth.uid()
    AND is_featured = false
  );

CREATE POLICY "products_admin_update_platform"
  ON products FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    AND source_type = 'platform'
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    AND source_type = 'platform'
  );

CREATE POLICY "products_manager_update_own"
  ON products FOR UPDATE
  USING (
    source_type = 'manager'
    AND owner_manager_id = auth.uid()
  )
  WITH CHECK (
    source_type = 'manager'
    AND owner_manager_id = auth.uid()
    AND is_featured = false
  );

CREATE POLICY "products_admin_delete_platform"
  ON products FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    AND source_type = 'platform'
  );

CREATE POLICY "products_manager_delete_own"
  ON products FOR DELETE
  USING (
    source_type = 'manager'
    AND owner_manager_id = auth.uid()
  );

-- ---- product_skus ----
ALTER TABLE product_skus ENABLE ROW LEVEL SECURITY;

CREATE POLICY "product_skus_select_via_product"
  ON product_skus FOR SELECT
  USING (public.can_view_product(product_id, auth.uid()));

CREATE POLICY "product_skus_admin_write_platform"
  ON product_skus FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM products p, profiles pr
      WHERE p.id = product_skus.product_id
        AND p.source_type = 'platform'
        AND pr.id = auth.uid()
        AND pr.role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM products p, profiles pr
      WHERE p.id = product_skus.product_id
        AND p.source_type = 'platform'
        AND pr.id = auth.uid()
        AND pr.role = 'admin'
    )
  );

CREATE POLICY "product_skus_manager_write_own"
  ON product_skus FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM products p
      WHERE p.id = product_skus.product_id
        AND p.source_type = 'manager'
        AND p.owner_manager_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM products p
      WHERE p.id = product_skus.product_id
        AND p.source_type = 'manager'
        AND p.owner_manager_id = auth.uid()
    )
  );

-- ---- product_image_generations ----
ALTER TABLE product_image_generations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "product_image_gens_select_own"
  ON product_image_generations FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "product_image_gens_admin_select_all"
  ON product_image_generations FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "product_image_gens_update_select"
  ON product_image_generations FOR UPDATE
  USING (auth.uid() = user_id AND status = 'ready')
  WITH CHECK (auth.uid() = user_id);

-- 写入由边缘函数用 service_role 完成，绕过 RLS

-- ---- product_share_grants ----
ALTER TABLE product_share_grants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "product_share_grants_manager_select_own"
  ON product_share_grants FOR SELECT
  USING (auth.uid() = manager_id);

CREATE POLICY "product_share_grants_client_select_own"
  ON product_share_grants FOR SELECT
  USING (audience = 'specific' AND auth.uid() = client_id);

CREATE POLICY "product_share_grants_admin_select_all"
  ON product_share_grants FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "product_share_grants_manager_write_own"
  ON product_share_grants FOR ALL
  USING (auth.uid() = manager_id)
  WITH CHECK (auth.uid() = manager_id);

-- ---- avatar_profiles_cache ----
ALTER TABLE avatar_profiles_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY "avatar_profiles_cache_select_authenticated"
  ON avatar_profiles_cache FOR SELECT
  USING (auth.role() = 'authenticated');

-- 写入由边缘函数用 service_role 完成
