-- ====================================================================
-- 商城 1.A.1：商品审核流程
-- 状态机扩展：draft / pending_review / rejected / active / archived
-- - manager 不能直接 active，只能提交审核
-- - admin 通过 admin_review_product RPC 通过/驳回
-- - 列锁触发器防止 manager 篡改审核字段
-- - 同步收口：products / product_skus RLS 全部改用 is_admin/is_manager helper
-- ====================================================================

-- ============ A. 扩展 status CHECK 约束 ============
ALTER TABLE products DROP CONSTRAINT products_status_check;
ALTER TABLE products ADD CONSTRAINT products_status_check
  CHECK (status IN ('draft','pending_review','rejected','active','archived'));

-- ============ B. 新增审核字段 ============
ALTER TABLE products
  ADD COLUMN submitted_at TIMESTAMPTZ,
  ADD COLUMN reviewed_at  TIMESTAMPTZ,
  ADD COLUMN reviewed_by  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN review_note  TEXT NOT NULL DEFAULT '';

ALTER TABLE products ADD CONSTRAINT products_review_note_length
  CHECK (char_length(review_note) <= 500);

COMMENT ON COLUMN products.submitted_at IS '管理师最近一次提交审核时间';
COMMENT ON COLUMN products.reviewed_at  IS '超管最近一次审核操作时间';
COMMENT ON COLUMN products.reviewed_by  IS '超管最近一次审核操作者';
COMMENT ON COLUMN products.review_note  IS '驳回原因（approve 时清空，reject 时必填，≤500 字）';

-- 待审队列索引（FIFO）
CREATE INDEX idx_products_pending_review_queue ON products (submitted_at DESC)
  WHERE status = 'pending_review';

-- ============ C. DROP 旧 RLS（products + product_skus） ============
DROP POLICY IF EXISTS "products_admin_insert_platform" ON products;
DROP POLICY IF EXISTS "products_manager_insert_own"     ON products;
DROP POLICY IF EXISTS "products_admin_update_platform"  ON products;
DROP POLICY IF EXISTS "products_manager_update_own"     ON products;
DROP POLICY IF EXISTS "products_admin_delete_platform"  ON products;
DROP POLICY IF EXISTS "products_manager_delete_own"     ON products;

DROP POLICY IF EXISTS "product_skus_admin_write_platform" ON product_skus;
DROP POLICY IF EXISTS "product_skus_manager_write_own"    ON product_skus;

-- ============ D. CREATE 新 RLS（统一 helper + 状态机收口） ============

-- products INSERT
CREATE POLICY "products_admin_insert_platform"
  ON products FOR INSERT
  WITH CHECK (
    public.is_admin(auth.uid())
    AND source_type = 'platform'
    AND owner_manager_id IS NULL
  );

CREATE POLICY "products_manager_insert_own"
  ON products FOR INSERT
  WITH CHECK (
    public.is_manager(auth.uid())
    AND source_type = 'manager'
    AND owner_manager_id = auth.uid()
    AND created_by = auth.uid()
    AND is_featured = false
    AND status IN ('draft', 'pending_review')
  );

-- products UPDATE：admin 高信任（任意 source）
CREATE POLICY "products_admin_update_all"
  ON products FOR UPDATE
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

-- products UPDATE：manager 仅限自己，且 status 只能是合法管理师态
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
    AND status IN ('draft', 'pending_review', 'archived')
  );

-- products DELETE
CREATE POLICY "products_admin_delete_platform"
  ON products FOR DELETE
  USING (
    public.is_admin(auth.uid())
    AND source_type = 'platform'
  );

CREATE POLICY "products_manager_delete_own"
  ON products FOR DELETE
  USING (
    source_type = 'manager'
    AND owner_manager_id = auth.uid()
    AND status IN ('draft', 'rejected', 'archived')
  );

-- product_skus 写策略（沿用 helper，无功能改变）
CREATE POLICY "product_skus_admin_write_platform"
  ON product_skus FOR ALL
  USING (
    public.is_admin(auth.uid())
    AND EXISTS (
      SELECT 1 FROM products p
      WHERE p.id = product_skus.product_id
        AND p.source_type = 'platform'
    )
  )
  WITH CHECK (
    public.is_admin(auth.uid())
    AND EXISTS (
      SELECT 1 FROM products p
      WHERE p.id = product_skus.product_id
        AND p.source_type = 'platform'
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

-- ============ E. 审核字段列锁触发器 ============
CREATE OR REPLACE FUNCTION public.products_lock_review_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  -- service_role bypass（边缘函数或后台脚本）
  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;

  -- admin 放行（审核 RPC + 后台直改）
  IF public.is_admin(v_uid) THEN
    RETURN NEW;
  END IF;

  -- 管理师路径：审核字段只读
  IF NEW.review_note IS DISTINCT FROM OLD.review_note
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by THEN
    RAISE EXCEPTION 'products: review_note / reviewed_at / reviewed_by 为只读字段，仅超管审核 RPC 可写';
  END IF;

  -- submitted_at 仅在状态转入 pending_review 时可写
  IF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
     AND NOT (
       NEW.status = 'pending_review'
       AND OLD.status IS DISTINCT FROM 'pending_review'
     ) THEN
    RAISE EXCEPTION 'products: submitted_at 仅在提交审核时可写';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER products_lock_review_fields_trigger
BEFORE UPDATE ON products
FOR EACH ROW
EXECUTE FUNCTION public.products_lock_review_fields();

-- ============ F. 审核 RPC ============
CREATE OR REPLACE FUNCTION public.admin_review_product(
  p_id UUID,
  p_action TEXT,
  p_note TEXT DEFAULT ''
) RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row products;
  v_trimmed_note TEXT;
BEGIN
  -- 权限校验
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;

  -- 动作校验
  IF p_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'invalid action: %', p_action;
  END IF;

  v_trimmed_note := btrim(COALESCE(p_note, ''));

  -- reject 必须有备注
  IF p_action = 'reject' AND v_trimmed_note = '' THEN
    RAISE EXCEPTION 'rejection requires a non-empty note';
  END IF;

  IF char_length(v_trimmed_note) > 500 THEN
    RAISE EXCEPTION 'review_note too long (max 500)';
  END IF;

  -- 单语句 MVCC 守卫：只对仍在 pending_review 状态的行起效
  UPDATE products
  SET
    status = CASE WHEN p_action = 'approve' THEN 'active' ELSE 'rejected' END,
    reviewed_at = NOW(),
    reviewed_by = auth.uid(),
    review_note = CASE WHEN p_action = 'reject' THEN v_trimmed_note ELSE '' END
  WHERE id = p_id
    AND status = 'pending_review'
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION '商品已不在待审核状态或不存在';
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_review_product(UUID, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.admin_review_product(UUID, TEXT, TEXT) IS
  '审核 RPC：仅 admin 可调用；approve→active 清空备注；reject→rejected 写备注（必填）；并发安全（MVCC + 状态守卫）';